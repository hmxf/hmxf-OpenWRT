# 脚本目录

`scripts/` 只保存构建、输入管理、锁维护和生产校验工具。日常使用应优先通过仓库根目录的 `Makefile` 调用这些工具；脚本之间使用项目根目录解析后的绝对路径，不应依赖调用者的当前工作目录。

## 分类

| 目录 | 职责 | 主要内容 |
|---|---|---|
| `build/` | 编排 ImageBuilder、官方 rolling snapshot 与可选源码构建，生成目标配置 | 固定快照构建、nightly 临时上下文、源码 worktree 构建、源码配置渲染 |
| `cache/` | 管理 live APK 下载缓存及其确定性索引 | 缓存更新/复验、manifest 到精确 APK 的映射 |
| `inputs/` | 恢复、核验、持久化和暂存锁定的二进制输入及固件发布物 | ImageBuilder、软件包快照、nightly live 捕获/portable identity、安全解包人工审核 Artifact、快照 bundle、stable/nightly Release 资产 |
| `lib/` | 提供所有脚本共享的受控基础能力 | 配置白名单、锁解析、路径安全、项目 revision/候选输入契约，以及可恢复 draft 的 GitHub Release 发布原语 |
| `locks/` | 分类上游 stable/snapshot/feed 变化并生成、审核、采用新锁候选 | 更新指纹、最新版检查、两阶段刷新、候选事务应用 |
| `source/` | 获取和核验固定源码，并把项目配置应用到隔离 worktree | locked/full 获取策略、tag/commit/feed 校验、`.config` 组合 |
| `verify/` | 执行构建前及发布前的生产门禁 | 项目静态契约、镜像/manifest/ABI 校验、磁盘结构解析、x86 QEMU/OVMF 启动测试 |

`lib/` 不应反向调用其他分类。跨分类调用应通过公共路径常量或项目根目录定位，不能假定被调用工具与调用者位于同一目录。新增脚本时还必须纳入项目静态检查和锁候选的 plan-input 枚举。

## `tests/` 与生产门禁的边界

仓库根目录的 `tests/` 保存测试夹具和测试流程，例如针对错误锁、缓存冲突、并发恢复及不安全归档的正反例。这些测试验证工具行为，可以独立编排，也不会进入固件或在设备启动后运行。

`scripts/verify/` 则属于生产实现，不是可选的测试附件。正式构建和锁候选流程会直接调用其中的校验器；尤其是：

- 项目契约校验决定锁、策略、配置和脚本是否可以进入构建；
- 产物及磁盘结构校验发生在输出目录原子发布之前；
- x86 QEMU/OVMF 与 LuCI HTTPS 检查是 canonical x86 镜像的发布门禁；
- 软件包快照校验虽然与输入管理放在一起，但同样处于正式信任链中。

因此，移动或修改生产校验器必须按构建代码变更处理。测试通过不能替代生产门禁，生产门禁也不能从构建入口中拆除后仅留在 CI。

完整仓库结构和生成目录生命周期见 [`../docs/repository-layout.md`](../docs/repository-layout.md)。

## Nightly 的两级身份与冻结流程

nightly 只使用 `scripts/locks/check-upstream-updates.sh` 输出的完整状态文件。可构建的 snapshot 状态恰有 17 键：`STATE_SCHEMA`、`CHANNEL`、`REASON`、`LOCKED_STABLE_VERSION`、`LATEST_STABLE_VERSION` 5 个基本状态键；`SNAPSHOT_VERSION_CODE`、`SNAPSHOT_SOURCE_COMMIT`、`SNAPSHOT_FEEDS_SHA256`、`SNAPSHOT_TARGETS_SHA256`、`SNAPSHOT_PACKAGES_SHA256`、`SNAPSHOT_FINGERPRINT` 6 个 snapshot 身份键；以及 `NIGHTLY_IMAGEBUILDER_X86_64_FILE`、`NIGHTLY_IMAGEBUILDER_X86_64_SHA256`、`NIGHTLY_IMAGEBUILDER_RPI4_FILE`、`NIGHTLY_IMAGEBUILDER_RPI4_SHA256`、`NIGHTLY_IMAGEBUILDER_RPI5_FILE`、`NIGHTLY_IMAGEBUILDER_RPI5_SHA256` 6 个 ImageBuilder 键。三个目标的 version code 必须一致，其短 commit suffix 必须是各自 `profiles.json` 完整 40 位 commit 的前缀，而且完整 commit 必须逐字相同；两次完整采样也必须一致。`SNAPSHOT_FINGERPRINT` 是 64 位**上游检测指纹**，按 version code、完整 source commit、feeds 摘要、三个目标 ImageBuilder 摘要、`SNAPSHOT_PACKAGES_SHA256` 五部分计算，只回答“官方 rolling snapshot 是否发生变化”，不能直接作为 Release identity。最后一项来自三个 ImageBuilder 实际仓库 URL 的全部 `packages.adb`：每个索引写为 `url|sha256`，经 `LC_ALL=C sort -u`、LF 结尾规范化后对纯数据行求 SHA-256；因此只有下游二进制仓库变化也会触发 nightly。context 中以 `# url|sha256` 为首行的 `repositories/PACKAGES.sha256.tsv` 保存同一集合供捕获、暂存和恢复重算，并纳入 `CONTEXT.sha256`；任一视图不一致时输出 `none/snapshot-publishing-in-progress` 且不输出 snapshot identity，等待下一轮。

`prepare-nightly-context.sh` 会重新下载并核对三个 ImageBuilder 与 metadata，只有源码、feeds、source epoch 和内核系列一致时才生成 `build/nightly/<upstream-fingerprint>/context`。`build-nightly.sh` 随后固定执行以下闭环：

1. 用 live 官方签名仓库为 x86_64、Pi 4、Pi 5 的 minimal/full 做六组 warm-up，完整解析依赖并填充按上游指纹隔离的 APK 索引；这些 `capture-out` 只是捕获输入，不能发布。
2. `capture-nightly-package-snapshots.sh` 重新取得每个 ImageBuilder 仓库清单中的 `packages.adb`，用签名索引记录的 package hash 把两份 manifest 映射到精确缓存 APK，生成三个 `SNAPSHOT/<target>` package snapshot 及其便携 bundle。它还把 warm-up 的六份 manifest 和十个镜像摘要写入最终 context，把三份已核验 ImageBuilder 复制到最终输入目录，并生成只含根 `NIGHTLY_BUILD.env` 与完整 `context/` 的 `NIGHTLY_BUILD_CONTEXT.tar`。该 tar 固定路径顺序、source epoch、uid/gid 0 与 0755/0644 mode，跨主机元数据一致；warm-up 后索引漂移、缺包、同名异内容或摘要/元数据不一致都会失败关闭。
3. `nightly-build-identity.sh` 是唯一公式实现：它严格按 x86_64、rpi4、rpi5 顺序从 `package-snapshots.tsv` 生成三行 `target|tree_sha256sums_sha256` 并计算 portable 内容身份，再计算 `sha256("nightly-build-v1\n" + upstream_fingerprint + "\n" + plan_inputs_file_sha256 + "\n" + package_snapshot_content_sha256 + "\n")`。这让最终身份绑定实际仓库树，而不因 tar/zstd 容器字节变化而漂移；完整 `package-snapshots.tsv` 文件的 SHA-256 仍单独约束 bundle 文件名、摘要和字节数。结果是完整 64 位**最终构建指纹**。
4. `build/nightly/<final-fingerprint>/NIGHTLY_BUILD.env` 恰有 `NIGHTLY_BUILD_SCHEMA`、`UPSTREAM_FINGERPRINT`、`PLAN_INPUTS_SHA256`、`PACKAGE_SNAPSHOTS_SHA256`、`PACKAGE_SNAPSHOT_LOCK_SHA256` 和 `NIGHTLY_FINGERPRINT` 六键；上游目录的 `NIGHTLY_BUILD_POINTER.env` 必须与它逐字节相同。最终六组强制使用 `ARTIFACT_LOCK_POLICY=enforce`、`PACKAGE_REPOSITORY_MODE=snapshot` 和 `PACKAGE_CACHE_INDEX=0`，既命中 warm-up manifest/镜像锁，也只读取三份冻结快照；它们保持 `candidate_build=1`、`development_build=0`，不会冒充 stable canonical。只有 `build/nightly/<final-fingerprint>/out/SNAPSHOT/` 可以交给固件暂存器；Release tag 必须是 `nightly-<完整64位最终指纹>`，短前缀只可用于人类可读日志。

两级临时锁只能配合 `configs/build-nightly.env` 与 `BUILD_CHANNEL=nightly` 使用，不可替换 `locks/`。三个 ImageBuilder/live APK 缓存可以复用，但每次读取仍核验外部摘要、索引字段和包内容；最终 package snapshot 受 portable 树身份、完整 `package-snapshots.tsv` 摘要和树内 `SHA256SUMS` 多层约束。`build-nightly.sh ... capture` 可只完成冻结阶段，`build-nightly.sh ... rebuild <target>` 可从已存在且完整核验的 pointer/final context 离线复建一个目标的 full/minimal；根目录的 `make nightly` 始终执行完整 capture 加六组复建。

nightly Release 恰有 33 个文件，`SHA256SUMS` 恰有 32 行并覆盖其他全部文件。除固件、metadata 和八份独立溯源外，它携带 7 个耐久重建输入：`NIGHTLY_BUILD_CONTEXT.tar`、targets lock 中三个原名 ImageBuilder、package-snapshot lock 中三个原名 bundle。`restore-nightly-inputs.sh RELEASE_ASSET_DIR [BUILD_NIGHTLY_ROOT]` 要求扁平、完整、无链接的 Release 目录，复算全部身份，安全解包 context/snapshots，再原子恢复 final 根和 upstream pointer；根 Make 入口为 `make restore-nightly NIGHTLY_ASSETS=/path/to/flat-release-assets`。之后对保存的 `UPSTREAM_STATE.env` 调用 `build-nightly.sh ... rebuild <target>` 即可不访问 live 仓库复建。

`scripts/lib/github-release.sh` 供 workflow 的 stable locked inputs、stable firmware 与 nightly firmware 共用。仓库必须启用 GitHub Immutable Releases；需要 `Administration(read)` 的设置端点只供仓库所有者在本地初始化/维护时通过 `github_require_immutable_releases_enabled` 核验，Actions 的 `GITHUB_TOKEN` 不请求该权限，workflow 也不调用该端点。helper 的显式 `gh api` 请求固定 `2026-03-10` 版本；已有未公开 draft 只有在 tag、目标 commit、draft/prerelease 类型全部符合预期时才可替换资产，随后必须从 GitHub 逐项回读、比较并复验 `SHA256SUMS` 才能公开。`github_publish_draft_and_require_immutable` 公开后轮询 Release 元数据，只有显式 `immutable=true` 才成功；若对象仍可编辑，它会尽力退回 draft，重新核验 draft/prerelease 类型并从 GitHub 逐字节复验资产，随后失败关闭；退回失败同样直接失败。已公开对象必须显式 immutable，脚本也只接受逐字节一致的幂等复用。stable locked-input 更新先复验 draft，再以精确 lease 推送锁，之后重绑 draft tag 并单次公开；推送后中断时，后续流程只能用当前锁逐字节恢复该 draft。stable firmware 在公开时设为 latest，nightly 始终为 prerelease/non-latest。工作流内部 artifact 名只绑定 `github.run_id`，不绑定 `run_attempt`，以便同一次运行的重跑覆盖同一逻辑传递槽；但人工审核入口额外锁定 REST Artifact ID 与原始 ZIP SHA-256，只按 ID 下载并由 `extract-reviewed-candidate.py` 安全解包，重跑产生新 ID 时旧审核自动失效。nightly 的每目标内部 artifact 暂时带第九个 `NIGHTLY_CONTEXT.sha256` 供汇总 job 比较三路 context；它通过后不作为独立 Release 溯源项，公开的八份独立溯源之外另有上述 7 个耐久输入。
