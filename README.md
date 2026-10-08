# ImmortalWrt 最新稳定版固件

每天自动检查 ImmortalWrt 正式稳定版源码。发现新的版本或稳定版 tag 对应的源码提交后，构建 x86_64、树莓派 4、树莓派 5 的 full/minimal 固件；补丁、小版本和大版本更新使用同一流程。已成功发布的源码跳过，失败的更新会在下次检查时重试。也可以在 Actions 手动选择 `force` 重建当前稳定版。

构建时按上游实际文件名和包索引选择输入。上游已经不提供的包自动移除，并记录在发布锁与 Release 说明中；下载、依赖解析、设备支持或必要功能验证失败都会终止发布。包清单继续保留原始意图，后续上游恢复提供时会重新纳入。

每次发布必须完成六种固件构建，然后使用冻结输入、关闭容器网络重复构建，比对全部镜像与完整软件包清单。验证包括 SquashFS 内容、3072 MiB 根分区、小于 4 GB 的镜像布局、x86 UEFI 启动及 LuCI HTTPS，以及树莓派 factory/sysupgrade 镜像结构。

只有全部成功后才生成 `LOCK.json`。镜像、锁、三个输入包、冻结的 Docker 构建环境和 `SHA256SUMS` 在同一个 Release 中发布。仓库不保存当前版本锁，不自动提交代码，没有 nightly 或整树源码构建流程。原有 Release 不会被删除。

## 本地重建

需要 x86_64 Linux、Python 3、Docker 和 zstd。下载目标 Release 的 `LOCK.json`，然后运行：

```sh
git clone https://github.com/hmxf/hmxf-OpenWRT.git
cd hmxf-OpenWRT
./rebuild.sh /path/to/LOCK.json
```

脚本校验锁引用的冻结输入和环境，载入当时的构建工具与仓库配方，在断网容器中编译并核对镜像摘要。输出在 `out/rebuild/targets/`。只重建一个设备时：

```sh
./rebuild.sh /path/to/LOCK.json --targets rpi5 --output out/rpi5-rebuild
```

锁中的哈希用于验证这一次发布的输入字节；寻找下一版时重新读取上游稳定版目录与包索引，不沿用旧包的哈希。输入和工具都保存在 Release 中，旧版本重建不访问上游。

## 仓库结构

- `.github/workflows/stable.yml`：唯一工作流，检查、构建、验证并发布。
- `scripts/firmware.py`：检查更新、取得输入、构建、生成锁、发布五个入口。
- `scripts/lib/`：输入、构建、验证、锁与 Release 函数。
- `scripts/verify/`：镜像结构验证与 x86 启动验证。
- `packages/*.txt`：基础包、full 驱动和仅运行时安装的应用清单。
- `files/`：ASU 和 HTTPS 功能配置。
- `Dockerfile`：随 Release 冻结的工具和配方。
- `tests/`：模块与流程的行为测试。运行 `make test`，需要 squashfs-tools 和 zstd。

自动适配以现有设备、ImageBuilder 和 APK 元数据格式为基础。若上游更改这些接口而无法继续验证固件，工作流会失败并保留最近一次成功发布，需要更新对应适配函数。
