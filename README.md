# hmxf-OpenWRT

这是面向 x86_64、Raspberry Pi 4 和 Raspberry Pi 5 的 ImmortalWrt 稳定固件配置仓库。当前审核版本、源码 tag/commit、ImageBuilder、内核 ABI、完整软件包 manifest 和最终镜像摘要都以 [`locks/`](locks/) 为唯一机器可读依据；三个设备各提供 `minimal`、`full` 两套预设，共六套镜像。上游是否已有新版只由独立检查报告，不改变已经审核的版本锁。

项目中不存在刷机后运行的安装脚本。仓库里的脚本只负责下载校验、配置、组装和验证镜像；刷机后的软件安装、驱动安装、备份和升级全部通过 LuCI 网页完成。

仓库的受控目录、脚本分类以及生成目录生命周期见[目录结构说明](docs/repository-layout.md)；本地测试入口、生产/开发构建测试的区别见[测试说明](tests/README.md)。

## 为什么选择 ImmortalWrt

本项目的刚需包括 PassWall、Tailscale、ZeroTier、WireGuard 和广告过滤。锁定的 ImmortalWrt 官方仓库直接提供这些软件及其 LuCI 中文包，能避免把第三方 feed 混进 OpenWrt 官方固件。ImmortalWrt 还默认采用 OpenSSL、dnsmasq-full、中文设置，并维护更多驱动和本地化补丁；代价是默认包集和维护面大于上游 OpenWrt。

如果只需要标准路由功能，OpenWrt 官方源码的上游边界更小、点版本通常更新更快；但在本项目的应用集合下，使用完整且一致的 ImmortalWrt 仓库更可靠。两者的固件、软件源和内核模块绝不能混用。

- [ImmortalWrt 下载首页](https://downloads.immortalwrt.org/)
- [ImmortalWrt 源码发布页](https://github.com/immortalwrt/immortalwrt/releases)
- [ImmortalWrt 发布目录](https://downloads.immortalwrt.org/releases/)
- [ImmortalWrt Sysupgrade Server](https://sysupgrade.immortalwrt.org/)

源码 tag 对象与 commit、全部 feeds、ImageBuilder、内核 ABI、六份完整解析 manifest、三份软件仓库快照及十个 canonical 镜像 SHA-256 都固定在 [`locks/`](locks/) 中。生产 `make image` 只读取经外部摘要锁定的本地快照；缺少输入时先从本项目对应的 locked-input Release（或显式 HTTPS 镜像）恢复，而不会重新解析滚动的上游 APK 仓库。普通本地 shell 的空缓存默认从 `hmxf/hmxf-OpenWRT` 恢复；CI 优先使用 `GITHUB_REPOSITORY`，两者都可由 `LOCKED_INPUT_GITHUB_REPOSITORY` 显式覆盖，也可提供后文的本地/HTTPS 输入源。独立定时流程每天检查严格稳定版以及官方 snapshot 的源码、feed、三个目标 ImageBuilder 和实际软件仓库索引指纹；stable 和 nightly 使用不同信任身份与 Release tag。

本项目所称“完全一致”专指在已提交且干净的项目树中、使用正式锁目录与 `configs/build.env` 的完整生产策略、不设置 `EXTRA_PACKAGES`、通过 `make image`/`make matrix` 产生的 canonical ImageBuilder 镜像：本地和 CI 调用同一脚本，任何包版本、传递依赖、APK 内容或主机工具导致的最终字节变化都会因完整 manifest 或外部镜像摘要锁不符而失败，不会用本次构建自行生成的摘要冒充审核基准。dirty/uncommitted、调试策略或候选外部锁构建只能标为 development/candidate。

官方发行系列的软件包目录可能滚动，单有摘要锁只能“发现并拒绝漂移”，不能让已删除的旧 APK 重新出现。`make refresh-locks` 会捕获实际使用的签名 `packages.adb` 和 APK，随后从该快照再构建全部六套并比较十个镜像摘要；审核者把三份快照 bundle 和三份 ImageBuilder 作为六个独立资产发布后，生产构建才有与上游生命周期无关的恢复源。`make apply-locks` 在采用候选前还会把解包快照、bundle 和 ImageBuilder 全部持久化到本地 `.cache/`。普通可选源码构建和带 `EXTRA_PACKAGES` 的定制构建始终不承诺 canonical 身份。

## 六套预设

| 设备 | 上游 target / profile | `minimal` | `full` |
|---|---|---|---|
| x86_64 | `x86/64` / `generic` | 官方 profile 驱动 + 安全管理基座 | 管理基座 + 完整的受支持网络驱动集 |
| Raspberry Pi 4/400/CM4 | `bcm27xx/bcm2711` / `rpi-4` | 板载硬件驱动 + 安全管理基座 | 管理基座 + 完整的受支持网络驱动集 |
| Raspberry Pi 5/500/CM5 | `bcm27xx/bcm2712` / `rpi-5` | 板载硬件驱动 + 安全管理基座 | 管理基座 + 完整的受支持网络驱动集 |

两种预设都明确包含：

- APK、CA 证书和基于 OpenSSL 的 HTTPS LuCI，HTTP 自动跳转 HTTPS；
- 简体中文 LuCI；
- LuCI 软件包管理器；
- LuCI Attended Sysupgrade 与 `owut` 后端；
- 只读 SquashFS、可写 overlay，以及固定 3072 MiB 根分区；
- 设备官方 profile 中不可缺少的启动、存储、板载网络驱动。

两种预设都**不包含** PassWall、Tailscale、ZeroTier、WireGuard 用户态工具或广告过滤应用。这些应用始终由用户在 LuCI 中按需安装、删除，并由 APK 自动解决依赖。

`minimal` 面向知道自己硬件型号的高级用户。它保留官方 profile 的默认驱动，但不额外加入驱动全集。若唯一的 WAN 网卡不在默认 profile 中，设备没有网络就无法在线补装该驱动；应改用 `full`，或在构建机上用 `EXTRA_PACKAGES` 把准确的一项预先加入。

在硬件已知且有稳定首个网口时，`minimal` 的只读基座更小、驱动攻击面和维护面也更小，是长期运行的优先选择。

`full` 面向常规用户。它额外包含：

- TUN、WireGuard、nftables NAT/socket/transparent-proxy 内核模块；
- Intel、Aquantia/Marvell、Broadcom、Mellanox、QLogic、Solarflare、Emulex、Realtek 等常见有线网卡，覆盖 10/100M 到 100G 的官方支持集合；
- 常见 ASIX、Aquantia、Realtek USB 网卡；
- Android RNDIS、CDC Ethernet/NCM 与 iPhone ipheth USB 网络共享；
- 可安全共存的主线 Intel、Qualcomm/Atheros、MediaTek、Realtek Wi-Fi 驱动和固件；
- Raspberry Pi 官方 profile 自带的板载网卡与板载 Wi-Fi 支持。

完整精确集合见 [`full-drivers-common.txt`](packages/full-drivers-common.txt) 及三个目标专用清单。为了避免驱动争抢，x86 使用 ImmortalWrt 默认的 Realtek vendor 路线，Pi 使用上游 `r8169`/`rtl8152` 路线；ath10k-ct、rtl8812au-ct 和会与主线模块重叠的旧 USB Wi-Fi 变体没有混装。

“完整网络驱动”指包清单中列出的、锁定版本为相应 target 正式发布且能无冲突共存的集合，不等于 Linux 支持过的每一张网卡，也不是把与路由无关的声卡、摄像头等模块全部塞进固件。刷新流程会在新版中重新解析每项驱动，包被删除、改名或冲突时会停止并要求人工审阅，而不会静默缩减集合。未列出的硬件应更换受支持网卡，或单独维护同内核 ABI 的源码构建和签名仓库；Pi 5 的 PCIe x1 即使能加载 100G 网卡，也无法达到 100G 线速。

## 分区与 4GB 介质

六套镜像统一使用 3072 MiB 根分区，minimal 与 full 可以在后续升级中保持相同分区几何：

| 设备 | 启动布局 | 写盘/分区占用边界 |
|---|---|---:|
| x86_64 | 标准 GPT + 32 MiB EFI/boot + SquashFS | 完整原始镜像约 3,255,074,304 字节 |
| Pi 4/5 | Pi 固件/FAT 64 MiB boot + SquashFS | 根分区声明末端 3,296,722,944 字节 |

最坏的 Pi 布局仍比十进制 `4,000,000,000` 字节少约 703 MB，因此能写入正常的标称 4GB U 盘或存储卡。构建校验读取 x86 GPT、Pi MBR 和根分区声明，并要求严格小于 4,000,000,000 字节；不会拿很小的 `.img.gz` 压缩体积冒充真实写盘需求。

x86 使用标准 UEFI + SquashFS `combined-efi.img.gz`。根文件系统固定为 SquashFS 4.0、XZ 压缩和 256 KiB block。Pi 使用硬件原生的 FAT 启动分区 + SquashFS，首次写卡用 `factory.img.gz`，以后通过 LuCI 升级用 `sysupgrade.img.gz`；Pi 不使用 GRUB EFI。

## 本地构建

构建机必须是原生 **Linux x86_64**，构建目录应位于支持稀疏文件、大小写敏感和 Unix 权限的本地文件系统；每个并行任务建议至少预留 8 GiB 可用磁盘空间。Ubuntu 24.04/Debian 类系统安装 ImageBuilder 与校验工具：

```sh
sudo apt-get update
sudo apt-get install -y build-essential curl file gawk gettext gzip python3 rsync shellcheck squashfs-tools unzip zstd
```

使用标准 `make image` 构建 x86_64 时还会在发布产物前自动执行 UEFI 启动测试，因此再安装：

```sh
sudo apt-get install -y ovmf qemu-system-x86
```

进入本仓库后可构建任意组合：

```sh
make validate
make test
# 独立检查是否已有新 stable；不属于固定版本构建前置
make check-latest

# 生成可供自动化或本地查询的 stable/nightly 分类状态
make check-updates

make image DEVICE=x86_64 PRESET=minimal
make image DEVICE=x86_64 PRESET=full
make image DEVICE=rpi4 PRESET=minimal
make image DEVICE=rpi4 PRESET=full
make image DEVICE=rpi5 PRESET=minimal
make image DEVICE=rpi5 PRESET=full
```

快捷目标：

```sh
# 三个设备都构建 minimal
make images PRESET=minimal

# 三个设备都构建 full
make images PRESET=full

# 一次构建全部六套
make matrix
```

需要主动验证当前官方 rolling snapshot 时，可生成一次强制 nightly 状态并构建六套非正式镜像；它不会修改 `locks/` 或 `out/`。`SNAPSHOT_FINGERPRINT` 只标识发现时的 version code、三个目标一致报告的完整 40 位源码 commit、feeds、三个 ImageBuilder 和实际 `packages.adb` 集合，并不是发布身份；`make nightly` 还会先做六组 live warm-up、冻结三个目标的软件包仓库，再从冻结输入离线复建六组，最终输出另一个完整 64 位构建指纹：

```sh
make check-updates UPDATE_MODE=nightly
make nightly
```

已下载某个 nightly Release 的全部 33 个文件时，可从扁平资产目录恢复发布时的冻结输入，而不重新访问 rolling 仓库：

```sh
assets=/path/to/nightly-release-assets
make restore-nightly NIGHTLY_ASSETS="$assets"

# 每个 rebuild 会离线复建该目标的 full 与 minimal
./scripts/build/build-nightly.sh "$assets/UPSTREAM_STATE.env" rebuild x86_64
./scripts/build/build-nightly.sh "$assets/UPSTREAM_STATE.env" rebuild rpi4
./scripts/build/build-nightly.sh "$assets/UPSTREAM_STATE.env" rebuild rpi5
```

恢复器严格要求 `SHA256SUMS` 有 32 行并覆盖除此文件自身以外的全部资产，复算上游/最终指纹和 plan-input 契约，再恢复 7 个耐久重建输入：确定性 `NIGHTLY_BUILD_CONTEXT.tar`、三个原名 ImageBuilder 和三个 package-snapshot bundle。它同时重建最终指纹目录、三份解包快照和上游 pointer；已有相同内容幂等复用，冲突内容失败。底层 `./scripts/inputs/restore-nightly-inputs.sh ASSET_DIR [BUILD_NIGHTLY_ROOT]` 可显式改变恢复根目录。

`make test` 是不下载上游数据的快速回归，独立执行静态、契约或组件测试可用 `make test-static`、`make test-contract` 和 `make test-component`。需要把真实本地编译当作测试且不污染正式 `out/` 时，使用 `make test-build DEVICE=x86_64 PRESET=minimal`；在尚未提交或正在改动的工作树中显式加 `TEST_MODE=development`。测试输出统一位于 `build/test-results/`，完整说明见 [`tests/README.md`](tests/README.md)。

不要使用 `sudo make`。下载数据按用途长期保存在本地，构建会先检查后复用：

- `.cache/imagebuilders/`：以 `locks/targets.tsv` 的外部 SHA-256 核验 ImageBuilder archive；
- `.cache/packages/<version>/<target>/`：ImageBuilder 按签名仓库索引校验并复用 APK；
- `.cache/packages/index.tsv`：项目自己的确定性缓存索引，记录 release、target、文件名、包名、版本、架构、字节数和 SHA-256；
- `.cache/package-snapshots/<version>/<target>/`：生产构建只读的软件仓库树，内部逐文件校验表本身也受正式外部锁约束；
- `.cache/package-snapshot-bundles/<version>/`：用于恢复上述仓库树的三个便携压缩包；
- `.cache/source-dl/`：可选源码构建的下载缓存，Buildroot 仍按对应 Makefile 哈希逐项核验。
- `.cache/nightly/`：按上游 snapshot 指纹隔离的非正式 ImageBuilder 与 live warm-up APK 缓存；读取时仍会复验摘要和包元数据，不会被生产 stable 构建读取。nightly 的三份冻结 package snapshot、三个锁定 ImageBuilder、确定性 context archive 和最终可发布输出位于对应的 `build/nightly/<最终64位指纹>/`；它们可由 Release 的 7 个耐久输入恢复，但 `.cache/` 本身不是信任根。

live 刷新和调试构建启用 APK 缓存索引。构建前会核验已经索引的本地文件，成功解析签名仓库并生成镜像后再原子更新索引；本地摘要不代替 APK 仓库签名。生产构建不从这个普通下载缓存选包，而使用内容冻结的 snapshot。可独立查询或复验 live 缓存：

```sh
make cache-verify CACHE_ROOT=.cache/packages
make cache-index CACHE_ROOT=.cache/packages

# 查询某个包已经保存的版本、架构和摘要
awk -F '\t' '$4 == "luci-ssl-openssl" { print $1, $2, $4, $5, $6, $8 }' \
  .cache/packages/index.tsv
```

`PACKAGE_CACHE_DIR` 可改到其他持久磁盘；启用索引时路径必须以 `<version>/<target>` 结尾。`DOWNLOAD_DIR`、`PACKAGE_SNAPSHOT_DIR`、`PACKAGE_SNAPSHOT_BUNDLE_DIR` 和 `SOURCE_DOWNLOAD_DIR` 可分别改变 ImageBuilder、已解包快照、快照 bundle 与源码下载缓存位置。不要把这些缓存提交到 Git；需要可移植、可证明的长期离线输入时应使用后文的六个 locked-input 资产。

新克隆的本地仓库若缓存为空，可直接从默认的 `hmxf/hmxf-OpenWRT` Release 恢复某一目标；已通过 byte size、SHA-256 和快照树摘要校验的对象以后会直接复用：

```sh
make prepare-inputs DEVICE=x86_64
make image DEVICE=x86_64 PRESET=minimal

# 在 fork/CI 中仍明确使用本项目 Release 时可覆盖仓库身份
LOCKED_INPUT_GITHUB_REPOSITORY=hmxf/hmxf-OpenWRT \
  make prepare-inputs DEVICE=x86_64
```

私有仓库同时设置有读取 Release 权限的 `GH_TOKEN`。不使用 GitHub 时，可改用扁平只读目录 `LOCKED_INPUT_SOURCE_DIR=/path/to/assets` 或 HTTPS 目录 `LOCKED_INPUT_BASE_URL=https://...`。

产物位于：

```text
out/<locked-version>/x86_64/minimal/
out/<locked-version>/x86_64/full/
out/<locked-version>/rpi4/minimal/
out/<locked-version>/rpi4/full/
out/<locked-version>/rpi5/minimal/
out/<locked-version>/rpi5/full/
```

ImageBuilder 产物文件名也带 `minimal` 或 `full`。每个目录含镜像、manifest、`profiles.json`、构建信息和 `SHA256SUMS`。脚本先在临时目录构建，并验证版本、target/profile、内核 ABI、解析 manifest、GPT/MBR、FAT 启动文件、SquashFS、Pi fwtool 元数据、HTTPS 配置及 4GB 几何；x86 还必须经 QEMU/OVMF 启动并通过模拟 LAN 返回 LuCI HTTPS 登录页。全部通过后才发布到目标目录，失败构建不会与旧文件混合。已有 x86 产物可再次执行 `make smoke-x86 PRESET=minimal` 或 `PRESET=full` 复验。

如果 minimal 的唯一初始网卡不在官方默认 profile 中，可在构建机上只加入准确驱动，例如 Intel E810：

```sh
EXTRA_PACKAGES='kmod-ice' make image DEVICE=x86_64 PRESET=minimal
```

`EXTRA_PACKAGES` 只允许用于 minimal，且最多选取 16 个该设备 full 清单中已审核的驱动或固件，不接受应用包、重复项或整套 full 复制。此类输出会标为 development，仍执行结构与可启动性校验，但不会冒充六套逐位锁定的标准镜像。

### 构建策略开关

所有语义开关都来自白名单解析的配置文件；未知键和非法值会立即失败，环境变量只适合单次显式覆盖。默认 [`build.env`](configs/build.env) 是生产策略，[`build-debug.env`](configs/build-debug.env) 是昂贵诊断策略，[`build-refresh.env`](configs/build-refresh.env) 只能由稳定锁刷新器使用，[`build-nightly.env`](configs/build-nightly.env) 只能与 `build/nightly/<完整64位上游或最终指纹>/context` 下相应阶段的临时锁一起使用。

| 行为 | 生产默认 | 调试/维护 |
|---|---|---|
| 产物锁策略 | `enforce`，完整 manifest 与外部镜像 SHA 必须命中 | 仅刷新器可用 `record` 生成候选 |
| APK 仓库 | `snapshot`，只读取经正式外部摘要认证的冻结目录 | `live` 仅供调试/刷新，用官方签名仓库制作下一份候选 |
| APK 本地索引 | 关闭；canonical 输入由 snapshot 的双层摘要契约约束 | live 调试和刷新开启，按包内元数据记录版本/架构并核验 SHA-256 |
| 上游最新版检查 | 不阻断固定构建 | 显式 `make check-latest` |
| 源码获取 | `locked` + `if-missing`，只要求审核 commit 的完整树 | `full` + `always`，全 refs/history/blob 与 full fsck |
| 固定 feed checkout | 若同级源码已有同 URL/commit 对象，则创建全新 shared checkout 并重建索引 | `off`，强制重新走网络浅克隆 |
| 源码 kmod 范围 | `preset` | `all` |
| 固定 feeds/刷新 Git 元数据重试 | 最多 3 次；feed 重试前删除未到锁定 commit 的半成品 | 可在策略中设为 1–5 次 |
| ImageBuilder 失败重试 | 同一临时树内最多 3 次并复用已校验下载 | 可在策略中设为 1–5 次 |
| 源码失败后的单线程详诊 | 关闭 | 开启 |
| x86 QEMU/OVMF 发布门禁 | 开启 | 可显式关闭但只能产生 development 结果 |
| 项目树 | 必须已提交且 clean | 可 dirty/uncommitted，身份降为 development |
| 网络代理 | `direct`，清除代理环境和 Git 用户代理、强制 TLS 校验，并忽略 curl 用户配置 | `inherit` |
| ImageBuilder/源码临时工作目录 | 成功/失败后清理 | 默认保留以便诊断 |

nightly 的发现/捕获阶段固定为 live 仓库、缓存索引开启、产物锁 `record`、项目 clean 要求关闭；这六组 warm-up 只用于得到完整解析 manifest、候选镜像摘要和 APK 缓存，绝不是可发布结果。捕获器随后按三个 ImageBuilder 内的仓库清单重新取得签名 `packages.adb`，用索引中的 package hash 把两套 preset 的 manifest 映射到精确 APK，生成 x86_64、Pi 4、Pi 5 三份内容锁定的 package snapshot，并把 warm-up 得到的六份 manifest/十个镜像摘要作为最终临时锁。离线复建强制改用 `PACKAGE_REPOSITORY_MODE=snapshot`、`PACKAGE_CACHE_INDEX=0` 和 `ARTIFACT_LOCK_POLICY=enforce`；六组结果必须命中 warm-up 锁，不能边构建边改基准。公共库还会验证临时锁路径、完整上游/最终指纹、portable 快照树身份、完整快照锁摘要和 `release_channel=nightly`，因此不能通过单个环境变量把 rolling 输入伪装成 stable canonical 构建。

例如，对完整源码历史做一次诊断检查：

```sh
BUILD_CONFIG=configs/build-debug.env make source-check DEVICE=x86_64 PRESET=minimal
```

若构建环境必须经过代理，先确认代理可用，再显式设置 `NETWORK_PROXY_MODE=inherit`；默认 direct 可避免本地失效代理造成“CI 成功、本地连接到错误端点”的差异。

### 可选源码校验与构建

默认源码仓库位于本仓库同级的 `ImmortalWRT` 目录。获取或核验：

```sh
./scripts/source/fetch-source.sh
./scripts/source/verify-source.sh ../ImmortalWRT
```

生产默认只获取 annotated tag 指向的审核 commit 及其完整工作树；已有该树时不会为了 freshness 强制联网，也不下载无关分支和 847 MiB 级完整历史。每次源码检查/编译仍从只读基准创建独立 detached worktree，不复用旧 `.config`、feeds、`bin` 或 `build_dir`。只有 `BUILD_CONFIG=configs/build-debug.env` 才补齐所有远程分支、tags、历史 blobs 并执行全对象检查。

源码 Buildroot 还需要：

```sh
sudo apt-get install -y build-essential clang flex bison g++ gawk \
  gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
  python3 python3-setuptools python3-pyelftools rsync swig unzip \
  zlib1g-dev file wget zstd
```

若实际执行 x86 源码构建（不只是 `CHECK_ONLY`），同样需要前文的 QEMU/OVMF；该产物也必须通过 LuCI HTTPS 启动门禁后才会发布。

只检查 feeds、DIY 配置和 `defconfig`：

```sh
make source-check DEVICE=x86_64 PRESET=minimal
make source-check DEVICE=rpi5 PRESET=full
```

确实需要修改内核或补丁时才在本地全量源码构建：

```sh
make source DEVICE=x86_64 PRESET=full
```

`scripts/source/apply-source-config.sh` 只验证固定源码和完整 feed 集，并组合自动生成的 target 配置与对应包清单，不修改上游源码、默认设置或下载第三方二进制。生产源码策略只构建 preset 实际选择的 kmod；诊断策略才启用 `ALL_KMODS`。源码产物会从自己的 `profiles.json` 记录并核验实际 vermagic，同时另记官方 ImageBuilder vermagic 作为不可混装边界；除非两者经独立确认完全一致，应只使用该次源码构建产生的模块。源码结果始终是 development 产物；正式固件使用官方 ImageBuilder 路径。

## 自动刷新版本锁

固定版本构建与版本发现保持分离，但 GitHub 的 [`upstream-check.yml`](.github/workflows/upstream-check.yml) 会在每天 UTC 02:17（北京时间 10:17）自动编排后续动作，也可手动选择 `auto`、`check`、`stable` 或 `nightly`：

1. 先解析官方下载目录中严格的三段稳定版本，并确认 x86_64、Pi 4、Pi 5 三个 ImageBuilder 及摘要均已就绪；新 stable 目录尚在分批上传时只记为 `deferred`，不会误降级为 nightly；
2. stable 优先：运行原有 live→snapshot 双构建刷新，先暂存 7 个 locked-input 文件并创建已远端逐字节复验的 draft；随后原子应用锁，自动提交只允许改变 `locks/**` 和三个生成的 target config，并以精确 lease 推送默认分支。推送成功后才把 draft 的 lightweight tag 重绑到新 commit 并一次公开，再从该 clean commit 构建 canonical 六组合并发布 `firmware-<version>`；
3. 没有 stable 更新时，比较官方 `/snapshots/` 三个目标的 `version.buildinfo`、`profiles.json`、`feeds.buildinfo`、ImageBuilder SHA-256 与 ImageBuilder 实际列出的全部 `packages.adb`。可构建的 `UPSTREAM_STATE.env` 必须恰有 17 键：5 个基本状态键，version code、完整 40 位 source commit、feeds/targets/package-index 三个集合摘要、`SNAPSHOT_FINGERPRINT`，以及三目标各一组 ImageBuilder 文件名/摘要。短 version suffix 必须是完整 commit 的前缀，且三个目标必须报告完全相同的完整 commit。包索引集合把规范 HTTPS URL 与索引 SHA-256 写成 `url|sha256` 数据行，经 `LC_ALL=C sort -u` 和 LF 结尾规范化后计算 `SNAPSHOT_PACKAGES_SHA256`；64 位**上游检测指纹**依次绑定 version code、完整 source commit、feeds、targets 和该 package-index 集合。因此即使源码与 ImageBuilder 未变，ImmortalWrt 已采用的下游二进制包仓库更新也会触发 nightly。三个目标的源码、feeds、epoch、内核版本或两次采样的软件仓库视图尚未同步时停止并等待下次 cron；
4. nightly 必须先用该上游指纹隔离缓存和临时上下文，完成六组 live warm-up；随后固定三个目标当时的 `packages.adb` 与实际解析到的 APK，制作三份 package snapshot，再完全离线复建六组。只有后半段结果可以暂存发布，warm-up 产物会被清理；
5. 最终 64 位构建指纹由 `scripts/inputs/nightly-build-identity.sh` 统一计算，输入为版本化域标记、上游检测指纹、当前 `PLAN_INPUTS.sha256` 文件摘要和 portable package-snapshot 内容身份。后者严格按 x86_64、rpi4、rpi5 顺序只哈希目标名与各自树内 `SHA256SUMS` 的摘要，因而绑定实际仓库树而不依赖 tar/zstd 容器字节；完整 `package-snapshots.tsv` 另有独立摘要约束 bundle 文件名、字节数和 SHA-256。Release tag 为 `nightly-<完整64位构建指纹>`；短前缀只可用于日志展示，不能用于去重、校验或发布身份；
6. nightly 不修改正式锁、不标记 canonical，也不更新 GitHub 的 latest stable Release。相同 stable tag 或完整 nightly 构建指纹只允许恢复正确 draft 或复用逐字节相同的已发布 Release，身份或内容冲突立即失败。

“下游组件更新”特指已经出现在 ImmortalWrt 官方 snapshot `feeds.buildinfo` 中的 packages、LuCI、routing、telephony 等固定提交变化。只看到某个 feed 仓库 HEAD 前进、但官方 snapshot 尚未采用并产出匹配二进制时不会抢跑构建。

每日检测不会依赖短期 Actions artifact 记忆上一轮 nightly。它会分页扫描已公开、显式 `immutable=true`、恰有 33 个资产的 `nightly-<64hex>` prerelease，要求 `SHA256SUMS` 的 32 行覆盖其余全部文件，核验 `NIGHTLY_BUILD.env`、`UPSTREAM_STATE.env`、7 个耐久输入及精确 lightweight tag。检测还会重新渲染当前 plan-input manifest 并比较其文件摘要；只有上游指纹和当前方案都与已发布溯源一致时才记为 unchanged，方案文件变化不会被误去重。任何缺资产、摘要错误、旧方案或身份不自洽的历史对象都不能充当耐久状态。

本地或手动维护仍可生成完整 stable 候选：

```sh
make check-latest
make refresh-locks VERSION=latest
```

也可把 `VERSION=latest` 换成明确三段版本号。刷新器不会边构建边改正式锁，而是在 `build/lock-refresh/<version>/` 中完成两阶段流程：

1. 远端核对 annotated tag 对象与 peeled commit，再从三个 ImageBuilder 自动提取完整 feeds、revision/epoch、target/profile、package arch、kernel/vermagic，确认文档列出的 LuCI 应用在每个 target 的官方包元数据中存在，并重新生成三个源码 config；
2. 使用 live 官方签名仓库构建六套 candidate，保存六份完整 manifest 和十个镜像摘要；
3. 捕获实际使用的签名仓库索引与 APK，按仓库签名哈希选择精确 APK，生成三个内容锁定的 package snapshot bundle，同时保存三份 ImageBuilder archive；
4. 只用捕获的本地仓库再构建六套，要求 manifest 原文和十个镜像摘要全部相同；
5. 输出 `PLAN_INPUTS.sha256`、生成时项目 revision 与 `REPORT.md`；刷新结束和应用前再次核对脚本、包清单、覆盖文件、旧锁、配置、文档及 CI 工作流没有发生变化。定时通道还限制自动 diff 的允许路径；需要真实 Pi 硬件兼容性认证时仍应在独立设备上复验，因为 CI 只能严格解析 Pi 镜像结构，不能模拟真实板卡外设。

审核候选后才显式应用：

```sh
make apply-locks CANDIDATE=build/lock-refresh/<version>
```

应用器会再次静态校验候选并复验第二套产物。替换 `locks/` 和自动生成的 target config 前，它先把 `package-snapshots/<version>` 保存为 `.cache/package-snapshots/<version>`，把三个 bundle 保存为 `.cache/package-snapshot-bundles/<version>`，并把三个 ImageBuilder 保存到 `.cache/imagebuilders/`。每项先在目标文件系统内 staging、完整比较后再发布；重复应用完全相同的版本不会重写文件，任何缺失、额外文件或字节差异都会失败，绝不会覆盖冲突版本。可用 `PACKAGE_SNAPSHOT_STORE_DIR`、`PACKAGE_SNAPSHOT_BUNDLE_STORE_DIR` 和 `IMAGEBUILDER_STORE_DIR` 改到持久磁盘（相对路径按项目根解析）。

`refresh-locks.yml` 也执行候选生成流程并按解析后的版本号上传结果，但 Actions artifact 只保留 90 天，不能充当正式输入源。运行摘要会记录本次 attempt 的 run ID、不可变 Artifact ID、原始 ZIP SHA-256、版本和 plan commit；审核必须绑定这组身份。同一 run 重跑会删除旧 Artifact 并创建新 ID，必须重新审核新字节，不能沿用旧摘要。审核候选后，先用 `make stage-inputs` 从候选生成恰好六个受锁资产及 `SHA256SUMS`，再发布到 `locks/release.env` 指定的 Release tag；已存在且内容冲突的 Release 资产不得覆盖。candidate 模式要求显式给出 `DESTINATION`，防止下一版本被误放进当前正式版本目录。也可把同一扁平目录发布到只读对象存储，并在本地/CI 设置 `LOCKED_INPUT_BASE_URL=https://...`。

```sh
make stage-inputs \
  CANDIDATE=build/lock-refresh/<version> \
  DESTINATION=dist/locked-inputs/<version>
```

定时 stable 通道会自动完成上述“先核验 draft、再推锁、重绑 tag 后单次公开、最后 canonical 构建”的事务。若默认分支已经成功推入新锁、但 draft 尚未来得及公开，下一次检测会分类为 `recover-locked-input-draft`：只从当前正式锁核对 draft 的全部 7 个字节锁定资产，重绑到当前 commit 并公开，然后继续 canonical build；它绝不会重新访问 live 仓库或生成另一份候选。手动回退路径仍可从受保护的默认分支运行 `publish-locked-inputs.yml`，输入运行摘要中的 refresh run ID、Artifact ID、Artifact SHA-256 和审核版本。它按 ID 查询对象，核对精确 workflow、仓库、默认分支、commit、run、未过期状态、字节数与 API digest，再按该不可替换 ID 下载原始 ZIP；ZIP 在任何解包前先复算人工审核的 SHA-256，随后用专用安全解包器拒绝路径穿越、重复路径、链接、特殊节点、文件/目录冲突和超限内容，并要求候选根目录形状完全一致。之后才核验 `PLAN_INPUT_REVISION.txt`，暂存 6 个 archive 加 `SHA256SUMS` 共 7 个文件并创建逐字节复验的 draft，再执行候选应用、完整门禁和受限路径检查，以精确 lease 提交新锁，最后把 draft tag 重绑到已推送 commit 并单次公开。若推锁后发布中断，同样由上述 `recover-locked-input-draft` 路径恢复。

仅在首次引导仓库或无法使用该 workflow 时才手工发布。先在 GitHub Settings 启用 Immutable Releases，再用拥有该仓库 `Administration(read)` 权限的所有者 `gh` 会话在本地执行设置端点核验；Actions 的 `GITHUB_TOKEN` 不具有该权限，workflow 不调用此端点。以下流程上传 `SHA256SUMS`、固定 tag 的目标 commit、先以 draft 回读，再复用与 CI 相同的发布后 immutable 门禁；禁止对身份未核实的 Release 使用 `--clobber`：

```sh
# 使用当前已经审核并暂存的版本
version=$(awk -F= '$1 == "IMMORTALWRT_VERSION" { print $2 }' locks/release.env)
release_dir="$PWD/dist/locked-inputs/$version"
tag="hmxf-openwrt-inputs-$version"
commit=$(git rev-parse HEAD)
owner_release_tmp=$(mktemp -d)
trap 'rm -rf -- "$owner_release_tmp"' EXIT
export GITHUB_REPOSITORY=hmxf/hmxf-OpenWRT
export RUNNER_TEMP="$owner_release_tmp"
. ./scripts/lib/github-release.sh

github_release_require_tools
github_require_immutable_releases_enabled

gh release create "$tag" \
  "$release_dir/SHA256SUMS" "$release_dir"/*.tar.zst \
  --target "$commit" --draft --latest=false \
  --title "hmxf-OpenWRT locked inputs $version" \
  --notes "Digest-locked build inputs; see locks in the reviewed source revision."

release_json="$RUNNER_TEMP/locked-input-release.json"
github_release_find_by_tag "$tag" "$release_json"
github_assert_release_metadata "$release_json" "$tag" true false
github_require_lightweight_tag_at_commit "$tag" "$commit"
github_verify_release_assets "$release_json" "$release_dir"
github_publish_draft_and_require_immutable \
  "$tag" false false "$release_dir"
github_require_lightweight_tag_at_commit "$tag" "$commit"
```

已构建的六个目录可用统一发布暂存器生成十个直接下载镜像、六个 metadata bundle、说明和顶层 `SHA256SUMS`。Pi 的 factory 是初次安装全量镜像、sysupgrade 是升级镜像；x86 的 combined EFI 完整磁盘镜像同时承担安装和镜像升级输入。`full` 表示完整驱动预设，不表示镜像了上游全部 APK：

```sh
make stage-firmware \
  CHANNEL=stable \
  IDENTITY="$version" \
  FIRMWARE_INPUT_ROOT="out/$version" \
  DESTINATION="dist/firmware/firmware-$version"
```

仓库创建后必须在 GitHub Settings 中启用 Immutable Releases。设置端点需要 `Administration(read)`，只在仓库所有者初始化/维护时由本地的 `github_require_immutable_releases_enabled` 核验；Actions 不请求这一仓库管理权限，也不调用该端点。脚本的显式 `gh api` 请求固定 `X-GitHub-Api-Version: 2026-03-10`；CI 在 draft 资产已从 GitHub 逐字节回读后才公开，随后轮询 Release 元数据并要求显式 `immutable=true`。字段缺失、解析/API 失败或轮询超时都失败关闭；若对象仍可编辑，helper 会尽力把它退回 draft，再核对类型并从 GitHub 逐字节复验资产，不论回退是否成功都使 job 失败。已公开对象只在显式 immutable 时可复用；stable 会在公开时设为 latest，nightly 始终是 prerelease 且 non-latest。

如果发布在创建 tag 或 draft 后失败，自动流程会保留现场。下一次运行只有在 lightweight tag 仍精确指向预期 commit、Release 类型与通道一致且对象仍为未公开 draft 时，才会用本次重新生成的完整资产集替换 draft 资产，远端逐字节下载、核验顶层 `SHA256SUMS` 后继续发布。这种 `--clobber` 只允许用于身份已经核实的 draft；启用 Immutable Releases 后，已公开 Release 的资产/tag 从平台层不可修改，工作流也只接受逐字节一致的幂等复用。来源不明、tag 指向错误或内容冲突都会失败。通常无需手工删除失败 draft；若必须清理，仍应先人工确认其 tag、目标 commit 和可见性，绝不能删除已公开或被其他流程使用的同名 Release。

默认生产构建会先校验本地已解压快照和 ImageBuilder；都正确时不联网。需要从自备离线归档目录构建时，目录必须保留 `<version>/<target>/` 层级：

```sh
PACKAGE_SNAPSHOT_DIR="$PWD/.cache/package-snapshots" \
DOWNLOAD_DIR=/path/to/imagebuilders \
make image DEVICE=x86_64 PRESET=minimal
```

此模式不会访问 live APK repositories；若已解包树缺失，恢复器会先核验本地 bundle，再尝试 `LOCKED_INPUT_SOURCE_DIR`、显式 HTTPS mirror 或 locked-input Release。GitHub 仓库身份优先取 `LOCKED_INPUT_GITHUB_REPOSITORY`，其次取 Actions 的 `GITHUB_REPOSITORY`，普通本地 shell 最终默认为 `hmxf/hmxf-OpenWRT`。六个二进制输入的信任根始终是正式锁中的 byte size 与 SHA-256，而不是下载 URL。

## 获取并校验 CI 产物

日常用户优先从仓库 Releases 下载：`firmware-<version>` 是正式 stable，`nightly-<完整64位构建指纹>` 是明确标记 prerelease 的 snapshot 构建。这个 nightly 指纹同时绑定上游输入、当前方案文件和三份实际软件包快照；检测阶段的 `SNAPSHOT_FINGERPRINT` 不能替代它。stable Release 有十个镜像、六个 metadata bundle、说明文件与顶层 `SHA256SUMS`，共 18 项。nightly 在这 18 项之外附带八份独立溯源文件和 7 个耐久重建输入，共 33 项；其 `SHA256SUMS` 精确覆盖其他 32 项。7 个输入是 `NIGHTLY_BUILD_CONTEXT.tar`、targets lock 中三个 versionless `SNAPSHOT` ImageBuilder 原名资产，以及 package-snapshot lock 中三个原名 bundle。任何镜像或恢复输入都应先按总表校验。

推送到 GitHub 后，[`ci.yml`](.github/workflows/ci.yml) 先调用可独立手动运行的 [`tests.yml`](.github/workflows/tests.yml)，全部测试成功后才调用 [`build.yml`](.github/workflows/build.yml) 的三目标生产矩阵。本地与 CI 都只调用同一组 `make` 入口。进入仓库的 “Actions → Continuous integration”，打开成功的运行，在 Artifacts 下载准确的一项：

```text
immortalwrt-<locked-version>-x86_64-minimal-run-<run-id>
immortalwrt-<locked-version>-x86_64-full-run-<run-id>
immortalwrt-<locked-version>-rpi4-minimal-run-<run-id>
immortalwrt-<locked-version>-rpi4-full-run-<run-id>
immortalwrt-<locked-version>-rpi5-minimal-run-<run-id>
immortalwrt-<locked-version>-rpi5-full-run-<run-id>
```

每项保留 90 天。解压 artifact 后先进入其目录并执行：

```sh
sha256sum -c SHA256SUMS
```

所有行都必须显示 `OK`。本地 `make image` 的输出目录执行同一命令。不要烧写摘要失败、缺少 `BUILD_INFO.txt`/manifest/`profiles.json`，或 `canonical_build` 不是 `1` 的标准发布产物。

## 安全烧写

首次烧写所用文件严格如下；x86 与 Pi、Pi 的 factory 与 sysupgrade 不能互换：

| 目标 | 首次写盘文件 | 后续 LuCI 升级文件 |
|---|---|---|
| x86_64 | `immortalwrt-<locked-version>-{minimal或full}-x86-64-generic-squashfs-combined-efi.img.gz` | 同一个 `combined-efi.img.gz` |
| Raspberry Pi 4 | `immortalwrt-<locked-version>-{minimal或full}-bcm27xx-bcm2711-rpi-4-squashfs-factory.img.gz` | 对应 `rpi-4-squashfs-sysupgrade.img.gz` |
| Raspberry Pi 5 | `immortalwrt-<locked-version>-{minimal或full}-bcm27xx-bcm2712-rpi-5-squashfs-factory.img.gz` | 对应 `rpi-5-squashfs-sysupgrade.img.gz` |

写盘前用 `lsblk` 确认目标是整块可移动介质而不是某个分区，字节容量必须大于 `3,296,722,944`。先在文件管理器中弹出该介质的所有已挂载分区，再次执行 `lsblk`，确认其 `MOUNTPOINTS` 全部为空。以下命令会完全覆盖 `/dev/sdX`；把它替换成刚刚核对的整盘设备名，绝不能写成当前系统盘。

x86_64 minimal 示例：

```sh
version=$(awk -F= '$1 == "IMMORTALWRT_VERSION" { print $2 }' locks/release.env)
cd "out/$version/x86_64/minimal"
sha256sum -c SHA256SUMS
lsblk -b -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
gzip -dk "immortalwrt-$version-minimal-x86-64-generic-squashfs-combined-efi.img.gz"
sudo dd if="immortalwrt-$version-minimal-x86-64-generic-squashfs-combined-efi.img" of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

Raspberry Pi 4 minimal 示例，只能解压并写入 factory：

```sh
version=$(awk -F= '$1 == "IMMORTALWRT_VERSION" { print $2 }' locks/release.env)
cd "out/$version/rpi4/minimal"
sha256sum -c SHA256SUMS
lsblk -b -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
gzip -dk "immortalwrt-$version-minimal-bcm27xx-bcm2711-rpi-4-squashfs-factory.img.gz"
sudo dd if="immortalwrt-$version-minimal-bcm27xx-bcm2711-rpi-4-squashfs-factory.img" of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

Raspberry Pi 5 minimal 示例：

```sh
version=$(awk -F= '$1 == "IMMORTALWRT_VERSION" { print $2 }' locks/release.env)
cd "out/$version/rpi5/minimal"
sha256sum -c SHA256SUMS
lsblk -b -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
gzip -dk "immortalwrt-$version-minimal-bcm27xx-bcm2712-rpi-5-squashfs-factory.img.gz"
sudo dd if="immortalwrt-$version-minimal-bcm27xx-bcm2712-rpi-5-squashfs-factory.img" of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

完整版只需在目录名和文件名中把 `minimal` 换为 `full`。不要用能同时匹配多个 `.img.gz` 的通配符，也不要把 Pi 的 sysupgrade 文件直接写到空白介质。也可以使用 Raspberry Pi Imager 的“使用自定义镜像”或 balenaEtcher，但仍须选择上表唯一正确的文件并先核对 SHA-256。

## 启动与首次进入 LuCI

- x86 机器选择 **x86-64 UEFI** 启动项并关闭 Secure Boot；本镜像没有厂商 Secure Boot 签名链，不要使用 Legacy-only 模式。实体网口枚举不保证与面板顺序一致，首次管理时可逐个网口尝试。
- Pi 4/5 用 microSD 首启最稳妥；使用 USB/NVMe 前，EEPROM 的 [`BOOT_ORDER`](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#BOOT_ORDER) 必须已允许对应介质。CM4/CM5 eMMC 版本应按 Raspberry Pi 官方 [`rpiboot` 写入流程](https://www.raspberrypi.com/documentation/computers/compute-module.html#flash-an-image-to-a-compute-module) 先把 eMMC 暴露成构建电脑的块设备，写完后移除启动/USB-slave 跳线并重新上电。
- 使用可靠电源，第一次启动给 overlay 初始化和 HTTPS 证书生成预留约 3 分钟，中途不要断电。Pi 板载以太网默认是 LAN，单网口型号不会凭空得到第二个 WAN；进入 LuCI 后再把支持的 USB/PCIe 网卡或手机共享接口配置成 WAN。

把电脑直连 LAN 后访问 `https://192.168.1.1`；输入 `http://192.168.1.1` 也会自动跳转到 HTTPS。首次证书由设备现场生成且为自签名证书，确认地址无误后接受浏览器提示并立即设置管理员密码。随后在“网络 → 接口”配置 WAN 并确认联网。此后的用户操作都在 LuCI 中完成，不需要终端。

如果 x86 完全无输出，依次检查 UEFI 模式、Secure Boot、启动顺序和写盘摘要；Pi 则先检查供电、介质和 EEPROM 启动顺序。静态校验和 CI 会真实用 QEMU/OVMF 启动 x86 镜像并访问 LuCI HTTPS；Pi 镜像会验证官方启动文件、DTB、内核、SquashFS 和 fwtool 元数据，但最终发布前仍建议分别在真实 Pi 4 与 Pi 5 上做一次硬件启动验收。

## 通过 LuCI 安装应用

进入“系统 → 软件包”，先点击“更新列表…”。切换到可用软件包，逐个精确搜索下表包名并点击“安装”。保持依赖检查开启，不要选择忽略依赖、强制覆盖或不受信任的软件源。主包和中文包都安装完成后刷新页面或重新登录 LuCI。

ImmortalWrt 的中国默认设置可能把下载端点显示为 `mirrors.vsean.net/openwrt`；它是 ImmortalWrt 预设的境内镜像，APK 仍校验发行版签名。不要手工加入 OpenWrt 官方、其他 fork 或无签名的 feed。

| 功能 | 在 LuCI 中安装的顶层包 |
|---|---|
| PassWall | `luci-app-passwall`、`luci-i18n-passwall-zh-cn` |
| Tailscale | `luci-app-tailscale-community`、`luci-i18n-tailscale-community-zh-cn` |
| ZeroTier | `luci-app-zerotier`、`luci-i18n-zerotier-zh-cn` |
| WireGuard | `luci-proto-wireguard` |
| 轻量去广告 | `luci-app-adblock-fast`、`luci-i18n-adblock-fast-zh-cn` |

WireGuard 的中文文本来自已内置的 `luci-i18n-base-zh-cn`，没有额外 WireGuard 中文包。APK 会自动加入以下依赖，无需用户逐项安装：

- PassWall 的 nftables 模块、DNS 工具以及当前官方构建选定的 sing-box、Xray、Shadowsocks Rust 等核心；
- Tailscale、ZeroTier 所需的 TUN；
- WireGuard 内核模块和工具；
- adblock-fast 所需的下载、DNS 与 ucode 组件。

不要使用 PassWall 页面里的“App Update/组件更新”去替换可执行文件；订阅和规则数据可以更新，程序版本只通过系统软件包仓库或 Attended Sysupgrade 更新。

卸载应用时进入“系统 → 软件包 → 已安装”，先删除相应中文包，再删除主包。下一次 Attended Sysupgrade 会按当时保留的顶层包重新组装 SquashFS，届时才会从新只读基座中彻底去掉已删除软件。

## 通过 LuCI 配置五项功能

### PassWall

进入“服务 → Pass Wall”，在节点订阅或节点列表中导入配置，先做 URL/连通性测试，再选择 TCP、UDP 节点并最后开启主开关。不要在仓库或固件 overlay 中预置订阅、节点或密钥。

### Tailscale

进入“服务 → Tailscale → 账户设置”，点击“登录”。LuCI 会打开 Tailscale 官方认证页，浏览器完成授权即可，不需要终端。手机安装官方 Tailscale App 并登录同一个 tailnet；这不是扫码配对。

只访问路由器自身时不要点击“自动配置防火墙”。需要访问路由器后方 LAN 时，在 LuCI 中填写要宣告的 LAN 网段并配置转发，再到 Tailscale 管理网站批准 Subnet Route；Exit Node 同样需要管理网站批准。当前 LuCI 的自定义 Auth Key 字段面向自定义控制服务器，不能替代官方控制平面的交互登录。

### ZeroTier

进入“VPN → ZeroTier → Configuration”，开启全局服务，在网络配置中新增真实 Network ID，并保留 `Allow managed`。除非确实需要，保持全局路由、默认路由和 DNS 接管关闭。需要从 ZeroTier 访问路由器时才允许 input，需要访问 LAN 时才允许 forward 并明确选择 LAN/NAT。最后在 ZeroTier Central 网页批准新成员。

### WireGuard

进入“网络 → 接口 → 添加新接口”，协议选“WireGuard VPN”。客户端模式可以导入服务商配置；自建服务端可在 LuCI 生成密钥、添加手机 peer 并显示二维码，手机 WireGuard App 扫码导入。随后在“网络 → 防火墙”建立独立 zone，按需允许到 LAN 的转发，并为 WAN 添加 UDP 监听端口规则。运营商 CGNAT 下仍需公网入口、上游端口转发或其他穿透方式。

### AdBlock Fast

进入“服务 → AdBlock Fast”，先只启用一个合适列表，DNS 模式选 dnsmasq servers file。若 PassWall 已开启 DNS Redirect，把 AdBlock Fast 的 “Force Router DNS” 关闭，只允许一方接管 53/853 重定向；高级设置中关闭 “Allow insecure downloads”，再保存、应用并重载服务。不要同时加入完整 adblock 或 AdGuardHome 争抢同一 DNS 通路。

Tailscale、ZeroTier 和 WireGuard 不要同时接收或宣告彼此重叠的默认路由。一次启用一项并验证，避免把管理流量导向错误隧道。

## minimal 中通过 LuCI 补装驱动

full 已包含文档范围内的驱动，常规用户无需执行本节。minimal 用户必须先通过现有网口联网，然后进入“系统 → 软件包 → 更新列表…”，搜索并安装准确包名，最后在“系统 → 重启”重启设备。常见映射如下：

| 硬件 | 软件包 |
|---|---|
| Intel I210/I211/I350 | `kmod-igb` |
| Intel I225/I226 2.5G | `kmod-igc` |
| Intel X520/X540/X550 10G | `kmod-ixgbe` |
| Intel X710/XL710/XXV710 | `kmod-i40e` |
| Intel E810 25/100G | `kmod-ice` |
| Aquantia/Marvell AQC 2.5/5/10G | `kmod-atlantic` |
| Broadcom NetXtreme-C/E 至 100G | `kmod-bnxt-en` |
| Mellanox ConnectX-3 及更早 | `kmod-mlx4-core` |
| Mellanox ConnectX-4 及更新 | `kmod-mlx5-core` |
| QLogic FastLinQ 至 100G | `kmod-qede` |
| Solarflare SFC9000/9100/EF100 | `kmod-sfc` |
| ASIX AX88179 USB 网卡 | `kmod-usb-net-asix-ax88179` |
| Aquantia AQC111 USB 网卡 | `kmod-usb-net-aqc111` |
| Android USB 共享 | `kmod-usb-net-rndis`、`kmod-usb-net-cdc-ether`、`kmod-usb-net-cdc-ncm` |
| iPhone USB 数据通路 | `kmod-usb-net-ipheth` |

Realtek 有冲突边界：x86 官方 profile 使用 `kmod-r8101/r8168/r8125/r8126` 和 `kmod-usb-net-rtl8152-vendor`；Pi profile 使用 `kmod-r8169` 与 `kmod-usb-net-rtl8152`。不要把另一条路线叠装到同一系统。Wi-Fi 应按芯片安装准确驱动和固件；full 的主线选择可直接查阅驱动清单。

内核模块必须来自设备当前同一个 ImmortalWrt 版本、同一个 target、同一个 kernel vermagic 的仓库。不要添加 OpenWrt 官方、其他 fork、其他架构或其他点版本的软件源。

## 手机 USB 网络共享

full 已包含 Android 和 iPhone 的数据面驱动。minimal 需要在仍有其他网络时，按上表从 LuCI 软件包管理器先安装对应驱动。

Android 是无终端场景最可靠的应急方案：连接数据线，在手机开启“USB 网络共享”，然后进入“网络 → 设备”观察新增设备；再到“网络 → 接口 → 添加新接口”，协议选择“DHCP 客户端”，设备选择刚出现的 USB/以太网设备，并把接口放入 `wan` 防火墙区域。不要把手机接口加入 LAN bridge。

iPhone 的 `ipheth` 数据面也在 full 中，但首次信任/配对没有完整的 LuCI 前端。可先在“系统 → 软件包”安装 `usbmuxd` 以改善激活和 carrier 恢复，然后解锁 iPhone 并确认信任提示；仍不能工作的首次配对场景不属于本项目承诺的纯 LuCI 路径。需要稳定的无终端应急 WAN 时优先使用 Android RNDIS/CDC。

## 备份与系统更新

进入“系统 → 备份/升级”，生成配置备份并用浏览器下载到另一台设备；不要只把备份留在路由器临时目录。

进入“系统 → Attended Sysupgrade”。本固件静态预置 `https://sysupgrade.immortalwrt.org` 和锁定的 3072 MiB rootfs，网页会收集现有顶层包，用匹配版本 ImageBuilder 重组一致的新 SquashFS，并在保留配置后升级。服务端策略属于外部状态；若网页明确拒绝该分区尺寸，不要临时改变布局，应改用本项目同设备、同预设的已校验升级镜像。

不要在“系统 → 软件包”中执行“全部升级”，尤其不要单独滚动 kernel、kmod、libc、网络、防火墙、无线或 DNS 基座。软件包管理器适合按需安装和删除应用；系统安全更新使用 Attended Sysupgrade。它减少人工重编和重装，但底层仍会写入完整的新基座镜像，不是块级增量更新。

如果 Attended Sysupgrade 暂时不可用，可从本项目下载同设备、同 UEFI/boot 类型、同 SquashFS 文件系统的升级镜像，在“系统 → 备份/升级”中上传。x86 始终保持 `combined-efi`，Pi 始终使用对应 `sysupgrade` 文件，且不要在后续升级中改变 3072 MiB 根分区。

## GitHub Actions

正式发布前先把本仓库提交并推送到 GitHub；未提交时 `BUILD_INFO.txt` 会标记 `project_commit=uncommitted`，已提交但工作树有变化时会附加 `-dirty`。这两类临时产物都不应作为可追溯的正式发布。

- `build.yml` 使用三个设备 job；每个 clean runner 先从 locked-input Release 恢复并复验该目标的 ImageBuilder 与 package snapshot，再用同一个冻结仓库依次构建 full、minimal。两套都与本地一样只调用 `make image DEVICE=... PRESET=...`，x86 smoke 位于该统一入口内部、原子发布之前；
- x86 target job 中的 full、minimal 两次构建都会使用 QEMU + OVMF 真正启动 UEFI/SquashFS，并从模拟 LAN 访问 LuCI HTTPS；
- `source-build.yml` 仅手动执行固定源码、feeds 与 `defconfig` 校验，不在空间有限的标准 runner 上冒充可靠的全量源码编译；
- `upstream-check.yml` 每天先分类 stable、nightly、deferred 或 unchanged；stable 通道完成双构建、locked-input 发布、受限路径锁提交、指定新 commit 的 canonical matrix 及正式固件 Release，nightly 通道执行“上游指纹发现 → 六组 live 捕获 → 三份 package snapshot → 六组离线复建”，并以完整最终构建指纹发布 immutable prerelease；
- `refresh-locks.yml` 与 `publish-locked-inputs.yml` 保留为人工维护回退入口；`source-build.yml` 仍只手动执行固定源码检查；
- 外部 Actions 固定完整 40 位 commit；上游解析、测试和构建 job 只有读取权限。由于 GitHub 只向具备 push access 的调用者列出 draft Release，一个不检出或执行上游代码、也不发出写请求的独立 locked-input draft 探针单独获得 `contents: write`，只把是否存在合规 draft 的布尔结果交给只读检测器；真正提交锁、创建 Release 和维护 keepalive 的 job 才使用写操作，跨 job 下载只增加 `actions: read`；
- 仓库级 Immutable Releases 必须保持启用，所有者初始化时在本地以 `Administration(read)` 查询设置端点，Actions 不请求该权限也不调用该端点；workflow 公开已远端复验的 draft 后轮询并要求显式 `immutable=true`，失败时尽力退回并再次逐字节复验 draft，然后失败关闭。显式 `gh api` 请求固定 `2026-03-10`；发布串行化由共享 concurrency group 保证，stable 在公开时设为 latest，nightly 只发布 prerelease/non-latest，已公开 tag 或资产绝不回写；
- 正式产物在通过锁定版本、目标/profile、内核 ABI、完整 manifest 前像、外部 canonical SHA-256、gzip/fwtool、启动文件、SquashFS、HTTPS 配置和分区几何校验后才上传，保留 90 天；PR 产物使用 `test-pr-*` 名称并只保留 14 天。

同版本的正式锁已经存在、但 `firmware-<locked-version>` 尚未发布时，定时流程不会重新访问滚动的 live 稳定仓库或重制锁。它先确认当前 `hmxf-openwrt-inputs-<locked-version>` 已公开、显式 immutable 且恰有锁声明的 7 个资产，然后直接从触发运行的当前 40 位 commit 调用 canonical matrix；若存在与当前锁完全一致但尚未公开的 draft，则走前述 `recover-locked-input-draft` 事务恢复。Release/draft 都缺失时状态改为 `deferred`，不会用不完整输入冒险恢复。

工作流顶层默认只有 `actions: read` 与 `contents: read`；上游解析、测试和构建保持只读。只有 stable 锁提交、Release 发布、月度 keepalive，以及上述只枚举 draft 且不执行任何写请求的隔离探针单独获得 `contents: write`。除纯只读 `check` 外，手动 `auto`/`stable`/`nightly` 也必须从事件声明的默认分支运行。stable 更新从事件载荷动态读取真实默认分支名，要求远端分支仍等于本次检测的 `github.sha`，并以该精确旧 commit 执行 `--force-with-lease`；默认分支已前进、被改名或 tag 指向异常都会失败，而不是覆盖并发提交。仓库 ruleset 若禁止 GitHub Actions actor 写入默认分支，管理员只应为这个锁更新 job/actor 配置精确 bypass，不能使用宽泛 PAT 或放宽整条分支。

GitHub 的 `schedule` 只执行默认分支上的 workflow，且公开仓库长时间没有活动时可能自动停用定时任务。为维持自动发现，`upstream-check.yml` 在每日检测之外每月运行一次权限隔离的 keepalive：只在 `automation/keepalive` 分支更新 `automation/KEEPALIVE.txt`，对该分支使用精确 `--force-with-lease`，绝不向默认分支制造空提交。这里依赖 GitHub 把该专用分支的真实提交计入仓库活动，是平台行为上的 best effort；如果定时 workflow 已被自动禁用，管理员仍须在 Actions 页面手工重新启用。运行还可能因负载延迟，因此保留 `workflow_dispatch` 用于补跑；仓库必须允许工作流创建/更新该专用分支。

本项目与 haiibo 方案只共享“配置仓库 + DIY + CI”的形式。这里不覆盖官方 feed 包、不批量浅克隆第三方源码、不修改 ImmortalWrt 默认源码、不混装无签名包仓库，也不提供任何刷机后脚本。
