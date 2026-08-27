# 工程执行逻辑

本文用框图描述当前仓库的实际执行路径。图中的“通过”都不是只检查命令退出码：正式构建还会核对版本锁、输入字节、软件包 manifest、内核 ABI、镜像结构和发布身份。任一身份不完整或上游视图不同步时，流程失败关闭，不会降级成未锁定构建。

## 正式 ImageBuilder 构建信任链

```mermaid
flowchart TD
    L["本地 make image / images / matrix"] --> E["Makefile → validate<br/>build-imagebuilder.sh"]
    C["build.yml 三目标矩阵<br/>每个目标 full → minimal"] --> R["prepare-inputs<br/>随后调用同一 make image"]
    E --> P
    R --> P
    P["严格解析 configs/build.env<br/>正式 locks + target + preset + clean tree"] --> V
    V["分别核验本地 ImageBuilder、<br/>解包 snapshot 与 snapshot bundle"] --> H{"ImageBuilder 和<br/>解包 snapshot 均有效?"}
    H -->|"是"| B
    H -->|"否"| S["按配置选择一个恢复路径<br/>有效本地 bundle / 本地资产目录 / HTTPS / immutable Release"]
    S --> A{"候选字节数、SHA-256、<br/>snapshot 树和签名索引均正确?"}
    A -->|"否"| STOP["失败关闭<br/>不静默接受其他身份"]
    A -->|"是"| SAVE["同文件系统原子写入 .cache"]
    SAVE --> B["ImageBuilder 只读取<br/>file:// 冻结软件仓库"]
    B --> G["发布前门禁：版本、target/profile、ABI、<br/>完整 manifest、镜像摘要、结构与 overlay"]
    G --> X{"x86_64 且策略要求启动测试?"}
    X -->|"是"| Q["QEMU + OVMF 启动<br/>探测 LuCI HTTPS"]
    X -->|"否"| O
    Q --> O["原子发布 out/version/target/preset<br/>canonical / candidate / development 身份互斥"]
```

production 的 `make image`、CI canonical 构建和 stable 发布共用 `scripts/build/build-imagebuilder.sh`，不会形成“本地一套、CI 另一套”的实现。环境变量只能覆盖已登记的配置键，不能注入任意 shell 内容。显式指定的恢复源若存在但身份错误会直接失败；不能依靠换下一个来源掩盖损坏或供应链漂移。

## 本地入口与策略边界

| 入口 | 实际策略 | 身份与输出 |
|---|---|---|
| `make test` | 离线执行 static → contract → component | 不生成固件 |
| `make image` / `images` / `matrix` | `configs/build.env`、正式冻结仓库、`enforce`、clean tree | canonical `out/` |
| `make test-build TEST_MODE=development` | 仍消费正式冻结仓库，只放宽 clean-tree 身份要求 | development `build/test-results/` |
| `make source-check` | locked tag/commit、隔离 detached worktree、固定 feeds，只执行 `defconfig` | 不生成正式镜像 |
| `make source` | 从同一固定源码实际编译 | 始终是 development |
| `make source-audit` | `configs/build-debug.env`：full history、always fetch、all kmods、诊断并保留工作树 | development |
| `make refresh-locks VERSION=...` | `configs/build-refresh.env`：stable live warm-up、冻结输入、离线复建 | candidate `build/lock-refresh/` |
| `make nightly` | `configs/build-nightly.env`：snapshot live warm-up、冻结输入、离线复建 | candidate `build/nightly/` |

`SOURCE_FETCH_MODE=full` 只在源码获取、`source-check` 或源码构建路径中生效；给普通 ImageBuilder 命令选择调试配置不会自动克隆源码。refresh 与 nightly 的 `record` 模式只能写入各自的指纹隔离目录，不可覆盖正式 `locks/` 或 stable `out/`。

## GitHub Actions 更新与发布编排

```mermaid
flowchart TD
    E{"触发事件"}
    E -->|"pull_request / push / manual CI"| T["可复用 tests workflow<br/>static → contract → component"]
    E -->|"手动 source-build.yml"| SRC["make validate + source-check<br/>固定源码 defconfig，不做全量源码编译"]
    T -->|"通过"| B["可复用三目标 build matrix<br/>每个目标依次 full + minimal"]
    T -->|"失败"| STOP["停止，不构建或发布"]
    B --> A1["CI artifacts<br/>构建入口内部仍执行正式门禁"]

    E -->|"每日 02:17 UTC / 手动"| DP["只列举当前 locked-input draft<br/>独立、可见但禁止任何写请求"]
    DP --> U["只读 detect<br/>稳定版 + snapshot 五段身份 + 历史 Release"]
    U --> S{"stable 优先分类"}

    S -->|"新 stable 已完整发布<br/>或手动 stable"| SP["live 构建并冻结候选<br/>六组合离线复建"]
    SP --> SD["创建并逐字节复验<br/>7 资产 locked-input draft"]
    SD --> SC["应用候选、跑完整门禁<br/>精确 lease 提交 locks/config"]
    SC --> SI["draft tag 重绑新 commit<br/>单次公开并要求 immutable"]
    SI --> SR["解析 canonical commit"]

    S -->|"同版本仅缺固件<br/>且 inputs 已公开"| SV["核验现有 7 资产 immutable inputs<br/>及 input tag 的正式方案树等价"]
    SV --> SR
    S -->|"已推锁且合规 draft 未公开"| REC["从当前正式锁逐字节恢复 draft<br/>重绑并公开"]
    REC --> SR
    S -->|"新版文件未齐<br/>或当前 inputs 与 draft 都缺失"| WAIT

    SR --> CB["三目标 canonical matrix<br/>每目标 full + minimal"]
    CB --> SF["暂存 10 镜像 + 6 metadata<br/>RELEASE_NOTES + SHA256SUMS"]
    SF --> ST["18 资产 draft 远端回读复验<br/>公开为 latest 且要求 immutable"]

    S -->|"没有 stable 动作"| Q{"三个 snapshot 目标<br/>是否双采样同步且稳定?"}
    Q -->|"否"| WAIT["none / deferred<br/>保留旧状态，等待下一轮"]
    Q -->|"是"| F{"检查模式，或上游指纹 + 当前方案<br/>是否已有合规 nightly?"}
    F -->|"check / 已发布"| NOOP["check-only / unchanged / fingerprint-already-published"]
    F -->|"检测到更新"| NC["capture：六组 live warm-up<br/>冻结三目标 package snapshots"]
    NC --> NB["rebuild：三目标并行离线复建<br/>每目标 full + minimal"]
    NB --> NS["stage：核对三路上下文一致<br/>生成最终 64 位构建指纹"]
    NS --> NP["33 资产 draft 远端复验<br/>公开 immutable prerelease，永不设 latest"]

    E -->|"每月 1 日 03:43 UTC"| K["只更新 automation/keepalive<br/>使用精确 lease，不触碰 main"]
```

stable、nightly 和 locked-input Release 都采用相同事务边界：先创建 draft，确认 tag/commit 和资产集合，逐项从 GitHub 回读并比较字节，最后才公开；公开后必须看到 `immutable=true`。中断留下的合规 draft 可以恢复，已公开对象绝不使用 `--clobber` 回写。

这里还有四个重要边界：

- 新 stable 的三个目标文件或摘要尚未齐全时分类为 `deferred`，不会降级发布 nightly；
- 仅下游仓库 HEAD 前进并不触发发布，变化必须已经进入官方 `feeds.buildinfo`、实际 `packages.adb` 或同步的 snapshot 二进制视图；
- `SNAPSHOT_FINGERPRINT` 只是上游检测身份，nightly tag 使用的最终指纹还绑定当前 `PLAN_INPUTS.sha256` 和三份 portable snapshot 树；live warm-up 固件不会发布，只有冻结输入的离线复建结果能进入 nightly；
- Actions artifact 只有 14/90 天传递用途；immutable Release 才是 stable 输入恢复和 nightly 历史去重的耐久状态。

## 本地缓存、冻结输入与信任根

```mermaid
flowchart LR
    L["locks/<br/>版本、大小、SHA-256、manifest、ABI、镜像摘要"] --> RQ["本次请求的精确输入身份"]
    RQ --> C1{"本地解包快照或 archive<br/>是否存在且复验通过?"}
    C1 -->|"是"| USE["直接复用"]
    C1 -->|"否"| SELECT["按配置选择恢复来源<br/>有效本地 bundle / 显式资产目录 / HTTPS / immutable Release"]
    SELECT --> VERIFY{"按外部锁复验通过?"}
    VERIFY -->|"否"| FAIL["失败关闭<br/>不把错误来源静默替换成另一身份"]
    VERIFY -->|"是"| SAVE["原子持久化到对应 .cache 分区"]
    SAVE --> USE
    USE --> BUILD["交给请求该精确对象的构建或捕获步骤"]

    LIVE["refresh / nightly 的 live APK"] --> META["核对 packages.adb 与 APK metadata"]
    META --> IDX[".cache/packages/index.tsv<br/>release + target + package + version + arch + size + SHA-256"]
    IDX --> HIT{"下次同一精确对象<br/>路径、大小、摘要和元数据都正确?"}
    HIT -->|"是"| REUSE["跳过下载"]
    HIT -->|"否"| REDOWNLOAD["重新获取、复验并原子替换"]
```

`.cache/` 只是可复用存储，不是信任根。canonical production 只消费正式锁指定的冻结 package snapshot，并关闭 rolling package-cache 解析；包索引主要服务于 refresh、nightly、调试和维护查询。要让旧版本在上游删除文件后仍可复建，必须保留对应 immutable locked-input Release 或其他与正式锁逐字节一致的归档。

## 主要输出与可恢复性

| 输出 | 身份 | 是否改变正式锁 | 持久恢复来源 |
|---|---|---:|---|
| `out/<stable>/...` | canonical | 否 | stable locks + 7 资产 locked-input Release |
| `build/lock-refresh/<version>/...` | candidate | 应用前否 | 审核 Artifact、候选快照与 ImageBuilder |
| `build/nightly/<final-fingerprint>/...` | nightly candidate | 否 | 33 资产 nightly Release 中的 7 个耐久输入及完整溯源 |
| 源码/调试输出 | development | 否 | 固定源码、feeds 与显式调试策略；不承诺 canonical 字节一致 |

任何构建若使用 dirty tree、额外包、live 仓库、调试开关或未正式应用的候选锁，都会与 canonical 身份分离，不能进入 stable Release。
