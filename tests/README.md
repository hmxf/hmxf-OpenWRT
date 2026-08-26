# 测试目录

`tests/` 保存项目的独立行为测试和本地构建验证入口。生产构建、输入恢复及发布前门禁仍属于 [`scripts/`](../scripts/README.md)；测试不会替代那些失败关闭检查，也不会进入固件 overlay。

## 快速离线测试

默认入口依次运行静态、契约和组件测试：

```sh
./tests/run.sh
./tests/run.sh all
```

也可以单独运行一层：

```sh
./tests/run.sh static
./tests/run.sh contract
./tests/run.sh component
```

仓库根目录的稳定 Make 别名分别是 `make test`、`make test-static`、`make test-contract` 和 `make test-component`；本地与 CI 应复用这些入口，不另写一套测试顺序。

| 层级 | 内容 | 网络与持久数据 |
|---|---|---|
| `static` | 调用生产项目校验器，检查锁、配置、脚本语法、ShellCheck、包清单和工作流契约 | 不联网，不修改缓存 |
| `contract` | 检查锁/config 的失败关闭行为、Markdown 链接/命令自洽，以及 workflow 的 17 键上游状态、33-asset、发布后 immutable 轮询/draft 回退和最小权限契约 | 不联网，夹具位于临时目录 |
| `component` | 检查 APK 缓存索引、ImageBuilder/快照持久化、locked-input 恢复、stable/nightly 更新分类、nightly 上游/最终身份、portable 快照树与确定性 context archive、33-asset 暂存/离线恢复、并发和恶意归档 | 不联网，全部使用合成小型夹具 |

运行器显式枚举测试文件，避免文件系统枚举次序改变执行结果。增加或重命名测试时必须同步更新 `run.sh`；测试应使用 `mktemp` 和退出 trap 清理现场，不得写入正式 `.cache/`、`dist/` 或镜像输出目录。

快速套件至少需要 Bash、Python 3、ShellCheck、GNU coreutils/findutils、`flock`、`tar` 和 `zstd`。它不需要真实 ImageBuilder、APK、QEMU 或外部网络。

## 本地固件构建验证

`run-build.sh` 在开始昂贵构建前先运行 `static` 层，并把通过生产发布门禁的结果统一写入：

```text
build/test-results/firmware/<version>/<device>/<preset>/
```

默认是 `canonical` 模式，可构建全部六套或一个明确组合：

```sh
./tests/run-build.sh matrix
./tests/run-build.sh canonical x86_64 minimal
./tests/run-build.sh canonical rpi5 full
```

对应的 Make 入口是 `make test-build DEVICE=x86_64 PRESET=minimal` 和 `make test-matrix`。二者通过 `TEST_MODE=development` 显式选择开发身份；未设置时 `TEST_MODE=canonical`。

Canonical 模式固定读取 `configs/build.env`，拒绝 `EXTRA_PACKAGES`，并要求项目已有提交且工作树干净。脚本完成后还会读取 `BUILD_INFO.txt`，确认结果确实标记为 `canonical_build=1`；不能满足这些条件时会失败，而不会自动降级。

开发中的未提交树使用：

```sh
./tests/run-build.sh development x86_64 minimal
./tests/run-build.sh development matrix
```

Development 模式仍使用生产 `build.env`、正式 snapshot、manifest/镜像摘要锁和 x86 启动门禁，只把 `REQUIRE_CLEAN_PROJECT` 设为 `0`，并要求最终身份为 `development_build=1`。它不是 `build-debug.env` 的 live 仓库、全量 Git 历史或保留工作树诊断模式。`EXTRA_PACKAGES` 只可用于一个显式 development 组合，并继续受生产构建器的 minimal/审核驱动限制。

固件构建需要项目主说明列出的 ImageBuilder 依赖；x86 还需要 QEMU 和 OVMF。缓存中缺少锁定输入时，构建器会按正式恢复顺序读取本地 bundle、离线资产目录、HTTPS 镜像或 immutable Release，因此该层不承诺离线。缓存和恢复行为、canonical 保证及镜像内容以[项目说明](../README.md)为准。

## 自动化编排

CI 通过独立的可复用测试 workflow 顺序运行 `static`、`contract` 和 `component`，并让普通固件 workflow 在整套快速测试成功后开始；也可用稳定的分层 Make 入口单独手动调度。workflow 内部传递槽的 artifact 名按逻辑内容与 `github.run_id` 固定，不加入 `run_attempt`，因此同一次运行的重跑不会让后续 job 寻找另一套名称。人工审核边界另行绑定不可变 Artifact ID 与原始 ZIP SHA-256：重跑产生新 ID 后必须重新审核；发布器只按 ID 下载、先验摘要，再以有恶意 ZIP 正反夹具覆盖的专用脚本安全解包。

定时发布 workflow 会先运行同一项目校验，再分别进入 stable 双构建或 nightly 冻结通道。nightly 组件夹具会验证三目标上下文、version code/完整 40 位 source commit/feeds/targets/package-index 五部分上游检测指纹、三个目标完整 commit 不一致时的延后行为、仅 `packages.adb` 字节变化的 nightly 分类、发布中视图不一致的延后行为、portable package-snapshot 内容身份、完整快照锁摘要和最终构建指纹之间不能混用；还检查 context tar 的固定顺序/时间/属主/mode、33 个 Release 文件与 32 行总表、7 个耐久输入恢复、幂等 pointer 修复及冲突拒绝。真实 CI 仍必须执行六组 live warm-up、制作三份 package snapshot，再以 `enforce` 策略从冻结仓库离线复建六组并命中 warm-up manifest/镜像锁。快速夹具不访问真实上游，也不替代实际包签名、镜像结构、x86 启动和远端 Release 回读门禁。

发布 job 的失败恢复同样属于生产行为：stable locked-input draft 在默认分支推锁后中断时，只能与当前正式锁逐字节匹配、重绑当前 commit 并单次公开；同版本只缺 stable firmware 时直接从 current-lock immutable inputs 做 canonical 恢复，不得把 live 仓库当测试捷径。GitHub 只向具备 push access 的调用者列出 draft，因此一个不检出或执行上游代码、也不发出写请求的隔离探针单独取得 `contents: write`，只把合规 draft 是否存在的布尔值交给仍为只读的检测器；契约测试固定并限制这条权限边界。它还要求显式 API 请求固定 `2026-03-10`、workflow 不调用需要 `Administration(read)` 的 immutable-releases 设置端点、公开 draft 后轮询到显式 `immutable=true`，并在对象仍可编辑时尽力退回已从 GitHub 逐字节复验的 draft 后失败关闭。设置端点只由仓库所有者初始化/维护时在本地核验。月度 `automation/keepalive` job 与每日检测分开授权，只维护专用远端分支；测试 workflow 本身始终保持只读。目录职责与生成数据的清理规则见[仓库结构说明](../docs/repository-layout.md)。

快速测试失败时应直接修复源码、锁、文档或测试，不要保留或手工修改临时夹具。固件测试输出位于被 Git 忽略的 `build/test-results/`，确认不再需要后可以整体清理；长期可复用且已校验的下载输入仍应保存在 `.cache/`。
