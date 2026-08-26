# 仓库目录结构

本仓库把受版本控制的构建方案、行为测试和可再生成的运行数据分开。目录位置本身是构建契约的一部分；移动文件时必须同步脚本引用、Make 入口、CI 路径过滤、ShellCheck source 注解、文档链接和候选 `PLAN_INPUTS.sha256` 枚举。

## 受版本控制的内容

```text
hmxf-OpenWRT/
├── .github/           GitHub Actions 与依赖更新配置
├── configs/           生产、调试、刷新策略及三个目标的源码配置
├── docs/              专题说明（通用构建、维护和使用入口仍在 README）
├── files/             写入固件根文件系统的静态 overlay
├── locks/             版本、源码、feed、输入、manifest 与镜像摘要锁
├── packages/          基础包、运行时应用和各目标驱动清单
├── scripts/           生产构建与维护工具
│   ├── build/         ImageBuilder、源码构建及配置渲染
│   ├── cache/         APK 缓存索引和快照映射
│   ├── inputs/        锁定输入的恢复、核验、持久化与分发暂存
│   ├── lib/           公共配置、锁和安全路径库
│   ├── locks/         上游检查、锁刷新及候选应用
│   ├── source/        固定源码获取、核验和配置组合
│   └── verify/        项目、产物、镜像结构及启动发布门禁
├── tests/             独立的契约和组件行为测试
├── LICENSE
├── Makefile           本地和 CI 共用的稳定命令入口
└── README.md          项目概览、保证边界和文档导航
```

`configs/`、`files/`、`locks/` 和 `packages/` 是固件方案数据，不属于测试夹具。`locks/README.md` 与锁文件同目录，专门说明机器可读锁契约；一般操作说明放在 `docs/`，测试依赖和测试分层说明放在 `tests/`。

## 测试与正式构建

`tests/` 中的脚本使用临时夹具验证失败关闭、幂等性、并发和路径安全等行为。它们适合由本地测试入口或独立 CI 质量流程编排，失败时不应留下候选、缓存或产物。

正式构建不能只依赖 CI 曾经运行过测试。`scripts/verify/` 和 `scripts/inputs/verify-package-snapshot.py` 是构建信任链的一部分，由本地与 CI 的相同构建入口直接执行，并在任何输出发布前检查锁定版本、包 manifest、内核 ABI、canonical 镜像摘要、磁盘结构、固件 overlay 以及需要的启动行为。这样，即使跳过独立测试流程，正式构建仍会失败关闭，而不会发布未经核验的镜像。

自动化测试采用独立的可复用 CI workflow，以便单独触发或作为生产矩阵的前置门禁；当前在其中按固定顺序运行静态、契约和组件测试。生产构建 workflow 仍须保留构建内部的发布前质量门禁，不能只依赖另一个 workflow 的成功状态。测试实现与生产构建共同通过 `Makefile` 暴露稳定入口，避免本地和 CI 形成两套命令。

## 生成目录及生命周期

以下目录不属于源码，应由工具创建且不提交到 Git：

| 目录 | 生命周期 | 内容与规则 |
|---|---|---|
| `.cache/` | 跨构建持久保留 | 已下载并核验的 ImageBuilder、APK、软件包快照、快照 bundle、源码下载缓存及索引；nightly 的 ImageBuilder/live APK 按完整上游检测指纹另行隔离。读取时仍须按正式锁、外部摘要、签名索引和包元数据重新核验；删除是可恢复的，但会失去离线复建能力并需要重新获取输入。 |
| `build/` | 临时 | 解包工作树、源码 worktree、测试数据、锁刷新候选，以及 nightly 的上游检测上下文、live warm-up、冻结 package snapshots、最终上下文和离线复建输出。正常成功或失败路径应清理无用中间目录；没有运行中的构建且候选/发布物已处理后，可以删除。它不是长期缓存或受版本控制的信任根。 |
| `out/` | 可再生成的镜像输出 | 通过生产门禁后原子发布的固件、manifest、`profiles.json`、`BUILD_INFO.txt` 与 `SHA256SUMS`。可按锁重新构建，不应被后续构建静默混入或覆盖。 |
| `dist/` | 可再生成的发布分发区 | 从正式锁或已审核候选暂存的 locked inputs，以及从已验证输出暂存的 firmware Release 镜像、metadata 与总校验表。它不是缓存信任根，也不能反向生成或修改正式锁。 |

四类目录不能混用：构建工作文件不得写进 `.cache/` 冒充已验证对象，未经校验的文件不得直接进入 `out/`，`dist/` 中的资产不得替代 `locks/` 中的大小和 SHA-256 信任根，测试夹具也不得写入任何正式持久缓存。

正式 stable 仍只发布 `out/<version>/` 中的 canonical 产物。nightly 使用两个不同且均为 64 位的身份层次：

- `build/nightly/<upstream-fingerprint>/context/` 保存由 version code、三个目标一致的完整 40 位 source commit、feeds、三个 ImageBuilder 摘要和实际 `packages.adb` 集合导出的上游检测上下文；其 `UPSTREAM_STATE.env` 必须恰有 17 键（5 个基本状态、6 个 snapshot 身份、6 个三目标 ImageBuilder 文件名/摘要）。规范化 `repositories/PACKAGES.sha256.tsv` 固定所有索引 URL 与摘要，同目录的 `capture-out/` 只是在六组 live warm-up 期间存在的解析结果，不能发布；`NIGHTLY_BUILD_POINTER.env` 记录本次捕获最终导出的构建身份。
- `build/nightly/<final-fingerprint>/` 保存六键 `NIGHTLY_BUILD.env`、绑定当前方案和 warm-up manifest/镜像摘要锁的最终 `context/`、确定性 `NIGHTLY_BUILD_CONTEXT.tar`、三份已核验 ImageBuilder、三份 `package-snapshots/SNAPSHOT/<target>/`、三个便携 bundle，以及 `out/SNAPSHOT/` 下从这些冻结仓库以 `enforce` 策略复建的固件。context tar 只含根 build state 与完整 context，按 source epoch、排序、uid/gid 0、目录 0755、文件 0644 固定元数据；安全恢复器会拒绝额外路径、链接、特殊节点或任一元数据漂移。最终指纹同时绑定上游检测指纹、`PLAN_INPUTS.sha256` 文件摘要与 portable package-snapshot 内容身份；完整 `package-snapshots.tsv` 的独立摘要还约束 bundle 容器字节。

nightly 经独立暂存后以 `nightly-<完整64位最终指纹>` 上传 prerelease；短前缀不是目录、tag 或去重身份。Release 恰有 33 个文件，顶层 `SHA256SUMS` 的 32 行覆盖其余文件。其中 context tar、三个 ImageBuilder 原名 archive 和三个 package-snapshot 原名 bundle 是 7 个耐久重建输入；`make restore-nightly NIGHTLY_ASSETS=/path/to/flat-release-assets` 会从它们重建上述 final 目录、三份解包快照和 upstream pointer，随后可离线执行 target rebuild。nightly 不会写入 `out/`、`locks/` 或 stable locked-input 缓存。GitHub Release 是自动化的耐久去重状态：身份正确的未公开 draft 可在重跑时恢复和远端复验，已公开对象必须显式 immutable 且不可覆盖。仓库所有者在本地初始化时核验需要 `Administration(read)` 的 Immutable Releases 设置端点；Actions 不调用该端点，而是公开已逐字节复验的 draft 后轮询 `immutable=true`，未达成时尽力退回并再次复验 draft，随后失败关闭。

`automation/keepalive` 是只供公开仓库月度调度保活的远端分支，不属于默认分支的源码布局。工作流只在该分支维护 `automation/KEEPALIVE.txt`，并使用精确 lease 防止覆盖并发变化；正常 checkout、构建方案和 plan-input 枚举不依赖这个文件。

## 清理原则

- 优先清理孤立的 `build/` 工作树、测试临时目录和已经可以重新暂存的 `dist/` 内容。
- 删除 `.cache/` 前应确认相同 locked inputs 仍可从本地归档、HTTPS 镜像或对应 Release 恢复；否则固定旧版本可能只能失败关闭。
- `out/` 可以删除，但若其中包含尚未分发的唯一已验证镜像，应先按 `SHA256SUMS` 复验并另行归档。
- 不直接编辑生成目录中的索引、摘要或快照树；应调用缓存、恢复、刷新或暂存工具，让更新保持原子性和可审计性。
- 锁刷新候选只能在完整审核和应用后清理。目录重新分类会改变 plan-input 路径，因此重组前生成的候选必须作废并在新结构下重新生成。
- nightly 的 live `capture-out/` 在三份快照成功捕获并完成最终复建后可立即删除；最终目录若仍是尚未发布的唯一可复验输入/输出，应先按 context、package snapshot 和固件总校验表归档或发布。
- 已经完整下载 33 个 nightly Release 文件时，可以删除对应 final 目录；需要复建时用 `restore-nightly` 重新生成。只保留七个耐久输入但没有同一 Release 的 `SHA256SUMS`、溯源文件及完整命名集合，不足以通过恢复门禁。
