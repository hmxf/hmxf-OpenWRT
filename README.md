# ImmortalWrt 最新稳定版固件

自动跟踪 ImmortalWrt 最新正式稳定版，构建并发布 x86_64、树莓派 4、树莓派 5 的 full/minimal 固件。

**本项目采用可复现构建。任何人都可以使用本仓库的重建脚本，以及目标 Release 提供的 `LOCK.json`、冻结输入和构建环境，重建出与该 Release 发布镜像逐字节相同、SHA256 一致的固件。**

[下载固件与重建文件](https://github.com/hmxf/hmxf-OpenWRT/releases/latest) · [查看自动构建](https://github.com/hmxf/hmxf-OpenWRT/actions/workflows/stable.yml)

## 自动构建与发布

每天检查上游稳定版目录和稳定版 tag 对应的源码提交。发现新的版本或源码提交后构建，补丁、小版本和大版本更新使用同一流程。已成功发布的源码跳过，失败的更新下次重试；仅软件包仓库或开发分支变化不会触发。也可以在 Actions 手动选择 `force` 重建当前稳定版。

构建时按上游实际文件名和包索引选择输入。上游已经不提供的包自动移除，并记录在发布锁与 Release 说明中；下载、依赖解析、设备支持或必要功能验证失败都会终止发布。包清单继续保留原始意图，后续上游恢复提供时会重新纳入。

每次发布必须完成六种固件构建，然后使用冻结输入、关闭容器网络重复构建，比对全部镜像与完整软件包清单。验证包括 SquashFS 内容、3072 MiB 根分区、小于 4 GB 的镜像布局、x86 UEFI 启动及 LuCI HTTPS，以及树莓派 factory/sysupgrade 镜像结构。

只有全部成功后才生成 `LOCK.json` 并公开 Release。每次发布提供 16 个文件：10 个镜像、`LOCK.json`、三个设备输入包、冻结的 Docker 构建环境和 `SHA256SUMS`。

自动适配以现有设备、ImageBuilder 和 APK 元数据格式为基础。若上游更改这些接口而无法继续验证固件，工作流会失败并保留最近一次成功发布，需要更新对应适配函数。

## 可复现构建与本地验证

复现过程使用该次发布冻结的官方 ImageBuilder、内核与软件包、构建工具和本仓库配方组装镜像。`LOCK.json` 记录源码与配方提交、输入摘要、软件包清单以及每个发布镜像的文件名、大小和 SHA256。

文件时间、镜像压缩头和磁盘标识沿用 OpenWrt/ImageBuilder 的原生可复现机制。构建脚本使用官方元数据中的 `SOURCE_DATE_EPOCH`，并固定 `LC_ALL=C`、`TZ=UTC` 和 `umask=022`；冻结输入归档按路径排序，规范化权限、所有者与时间戳。构建环境的软件包版本保存在冻结 Docker 镜像的包数据库中，重建时直接加载同一环境，无需重新安装可能已变化的系统依赖。

需要 x86_64 Linux、Python 3、Docker 和 zstd，无需维护者的 GitHub 凭据。先从目标 Release 下载 `LOCK.json`，然后运行：

```sh
git clone https://github.com/hmxf/hmxf-OpenWRT.git
cd hmxf-OpenWRT
./rebuild.sh /path/to/LOCK.json
```

脚本会自动下载同一 Release 的冻结输入与 Docker 环境，验证大小及 SHA256，再载入当时的工具和配方，在关闭网络的容器中重建。重建时逐项检查镜像字节摘要、完整软件包清单、元数据和镜像结构；x86 还会验证 UEFI 启动与 LuCI HTTPS。全部匹配后才报告成功。

镜像输出在 `out/rebuild/targets/<设备>/artifacts/<full或minimal>/`。默认重建全部设备和预设，只重建一个设备时：

```sh
./rebuild.sh /path/to/LOCK.json --targets rpi5 --output out/rpi5-rebuild
```

初次下载冻结文件需要联网，镜像重建过程不访问上游。即使上游文件、软件包或构建工具随后变化，只要保留该 Release 的完整重建文件，就可以复现该次发布。上述复现说明适用于提供完整 `LOCK.json`、冻结输入和构建环境的发布。

锁中的哈希用于校验某一次发布的输入与产物；寻找下一版时重新读取上游稳定版目录与包索引，不沿用旧包的哈希。仓库不保存当前版本锁，也不会为跟踪版本自动提交代码。

## 固件内的更新功能

仓库 Actions 检查上游源码，与已安装固件中的更新功能分别运行。当前固件使用以下官方服务：

| 功能 | 来源 | 作用 |
| --- | --- | --- |
| 软件包管理 | `downloads.immortalwrt.org` 对应版本、架构和内核 ABI 的 APK 仓库 | 安装或更新软件包 |
| 值守式系统升级 | `https://sysupgrade.immortalwrt.org` | 按设备和软件包清单请求新镜像，再执行 `sysupgrade` |

官方升级服务可以按清单重新嵌入软件包，但生成的镜像不等同于本仓库已验证的 Release 产物。对固定镜像执行 `sysupgrade` 时，保留配置不会自动保留用户后来安装的软件。跨系统版本和内核升级应使用匹配设备的完整镜像。

### 接入 GitHub Release 更新的改动范围

目前尚未实现设备端从本仓库 Release 自动检查、下载和升级。要接入这一路径，可以复用现有 `LOCK.json` 作为更新索引，继续使用现有构建与验证流程：

| 部分 | 需要补充的内容 |
| --- | --- |
| 镜像身份 | 写入设备、full/minimal、配方提交等标识，识别适用镜像和同版本重建；旧固件首次迁移需明确选择预设 |
| 升级客户端 | 读取最新发布锁，匹配设备、文件系统及 EFI 等条件，下载镜像，校验大小、SHA256 和 `sysupgrade` 兼容性 |
| LuCI 与配置 | 接入检查、下载、确认升级和配置备份入口；APK 软件包源继续独立配置 |
| 发布清单 | 为锁文件增加签名并在固件内置验签公钥；校验通过后才接受更新 |
| 配置与软件包恢复 | 明确保留配置的范围，记录用户额外安装的软件包并处理升级后的重装 |

接入后还需测试错设备、错预设、损坏镜像和同版本新发布等情况，并实际验证从旧固件升级到新固件及配置恢复。

最新发布锁可从固定地址取得：

```text
https://github.com/hmxf/hmxf-OpenWRT/releases/latest/download/LOCK.json
```

GitHub 提供更新清单和镜像文件，设备侧客户端负责交给 `sysupgrade` 刷写完整镜像。现有 ASU 客户端使用构建服务 API，不能只替换服务器网址来接入 GitHub Release。

## 仓库结构

- `.github/workflows/stable.yml`：唯一工作流，检查、构建、验证并发布。
- `scripts/firmware.py`：检查更新、取得输入、构建、生成锁、发布五个入口。
- `scripts/lib/`：输入、构建、验证、锁与 Release 函数。
- `scripts/verify/`：镜像结构验证与 x86 启动验证。
- `packages/*.txt`：基础包、full 驱动和仅运行时安装的应用清单。
- `files/`：当前官方 ASU 和 HTTPS 功能配置。
- `Dockerfile`：随 Release 冻结的工具和配方。
- `tests/`：模块与流程的行为测试。运行 `make test`，需要 squashfs-tools 和 zstd。
