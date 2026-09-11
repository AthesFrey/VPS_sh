# DD 后网络检测与修复：sh 版

新版使用单文件 `dd-network-fix.sh`，可直接由 `/bin/sh` 执行。**不依赖 Python，不安装软件，不下载或执行远程代码。**

它针对 Debian/Ubuntu 使用 ifupdown 时，`iface 网卡 inet6 dhcp` 可能拖住 networking，导致 IPv4 后续失联的情况。单凭“一小时失联”、DHCPv6 配置或 `Request renew in +3600` 不能确诊；脚本会列出配置、DHCP 客户端、networking 状态和相关日志。

## 使用

把 [dd-network-fix.sh](dd-network-fix.sh) 上传到目标 VPS，在脚本所在目录执行：

```sh
# 1. 自动识别网卡并检测；默认只检测
sudo sh dd-network-fix.sh --check

# 2. 确认该机器不依赖有状态 DHCPv6 后，备份并修复
sudo sh dd-network-fix.sh --fix
```

**修复成功后**再重启：

```sh
sudo reboot
```

重新 SSH 登录后复检：

```sh
sudo sh dd-network-fix.sh --check
```

如果已经是 root，省略 `sudo` 即可。无需 `chmod +x`，也无需使用 bash。

网卡默认根据 IPv4 默认路由识别；默认路由丢失时，会尝试选择唯一已存在且配置 IPv4 的网卡。多网卡无法明确选择时，指定实际网卡名：

```sh
sudo sh dd-network-fix.sh --fix --interface ens5
```

支持 `eth0`、`ens5`、`enp1s0` 等名字，`--interface` 可重复指定多张网卡。

## 修复方式

原配置：

```text
auto ens5
iface ens5 inet dhcp
iface ens5 inet6 dhcp
    accept_ra 1
    autoconf 0
```

修复后：

```text
auto ens5
iface ens5 inet dhcp
# dd-network-fix disabled DHCPv6: iface ens5 inet6 dhcp
# dd-network-fix disabled DHCPv6:     accept_ra 1
# dd-network-fix disabled DHCPv6:     autoconf 0
```

注释整个 DHCPv6 段，防止只删 `iface` 行后，剩余选项被解释为 IPv4 配置。IPv4 配置、其它网卡、独立的 IPv6 静态/SLAAC 段会保留。重复执行不会重复注释或再创建修复备份。

修复只修改持久配置，不会在 SSH 会话中执行 `ifdown`、重启 networking、终止 DHCP 进程或自动重启机器。**手动重启才会使修改完整生效。**

本项修复停止相应配置段在下次启动时启动有状态 DHCPv6，可能影响通过 DHCPv6 获取的 IPv6 地址、前缀和相关参数。它不全局禁用 IPv6；SLAAC 是否正常取决于平台的路由通告和本机设置。

## 依赖与边界

使用 Linux 上的系统命令：`sh`、`awk`、`grep`、`cp`、`mv`、`mktemp`、`readlink`、`stat`、`sha256sum`、`sync` 等 GNU coreutils 工具，以及用于网卡检测的 `ip`。正常在线修复还会使用 ifupdown 自带的 `ifquery` 验证修改前后的配置；缺失时会停止修改，不自动安装。

`systemctl`、`journalctl`、`ps` 用于补充运行状态，无法查询时会提示或省略对应信息。脚本不是面向 BusyBox/Alpine 的版本。

支持 `/etc/network/interfaces`、递归 `source`、`source-directory`/`source-dir`、普通路径通配符、反斜杠续行、CRLF 和无末尾换行的文件。

以下情况会停止自动修改并说明原因：

- 无法明确识别网卡，或目标网卡缺少 IPv4 DHCP/静态配置。
- systemd-networkd/NetworkManager 正在运行，或检测到 networking.service 不存在。
- DHCPv6 段中有自定义命令、DNS、MTU、桥接等选项。自动处理的 IPv6 段内选项限于 `accept_ra`、`autoconf`、`request_prefix`、`ll-attempts`、`ll-interval`、`privext`。
- mapping、rename、逻辑网卡映射、模板继承、source 引用循环、硬链接，或待修改文件实际位于 `/etc/network` 之外。
- source 路径含空格、引号、变量或命令替换；同一条 source 含多个路径。多个路径可以拆成多条 source。
- 配置在检测后被其它程序改写，或修改前后的配置解析不通过。

这不是 netplan、systemd-networkd 或 NetworkManager 配置修复器。检测到 cloud-init/自动生成标记时会提示检查生成来源；脚本不改动 cloud-init。

## 备份、回滚和恢复

备份保存在：

```text
/var/backups/dd-network-fix/时间戳-随机后缀/
```

包含原文件、`manifest.txt` 路径清单、`SHA256SUMS` 校验值和 `restore-commands.txt` 恢复命令。保留原文件权限、属主、时间及 `cp -a` 支持的扩展属性。

脚本先备份并同步到存储设备，再逐文件原子替换。普通错误、HUP/INT/TERM 中断会触发回滚；如果配置又被外部程序改写，则保留外部修改并提示手动恢复。断电或无法捕获的 SIGKILL 无法保证多文件修改一同回滚，需要使用备份。

恢复时，查看脚本实际输出的备份目录：

```sh
sudo cat /var/backups/dd-network-fix/实际备份目录/restore-commands.txt
```

核对后，以 root 执行其中的 `cp -a -- ... ...` 命令，然后重启。若修复后又手动修改过配置，应先比较差异。

并发修复通过备份目录下的 `.lock` 目录互斥。正常完成或可捕获中断会释放锁；若进程被强杀，先根据 `.lock/pid` 确认修复进程已经结束，再清理遗留锁。

## 重启后验证

复检时应看到目标 DHCPv6 段已停用，networking 不再持续 `activating` 或 `failed`，IPv4 地址和默认路由正常，并有适当的 DHCP 客户端负责续租。

配置已改、尚未重启时，旧的 DHCPv6 进程和 networking 失败状态仍可能存在。未看到 dhclient 也不一定有故障，机器可能使用其它 DHCP 客户端。

确认 SSH、探针等业务正常，并观察超过原来约一小时的故障窗口，最好跨过一次实际租约续租。脚本不主动断网或执行一小时等待试验。

## 返回值

| 返回值 | 含义 |
| --- | --- |
| 0 | 未发现本项配置，或修复成功/指定网卡无需修改；不代表网络完全健康或已经重启生效。 |
| 1 | 只读检测发现 DHCPv6 配置嫌疑。 |
| 2 | 参数、依赖或配置错误，无法自动处理，或修复失败。 |
| 130 / 143 | 被 INT / HUP、TERM 中断。 |

## 离线模式和测试

救援环境中可以检查/修复已挂载系统的配置：

```sh
sudo sh dd-network-fix.sh --root /mnt/vps --check
sudo sh dd-network-fix.sh --root /mnt/vps --fix --interface ens5
```

离线模式只读取该根目录内的配置，不查询当前机器的网络、不执行 ifquery，也不能确认实际网卡是否存在或网络健康。它使用脚本内的结构检查，适用于测试或已明确了解配置的救援场景。在线运行无需 `--root`。

测试同样由 sh 实现，全部使用临时目录和模拟网络命令，不修改宿主机网络：

```sh
sh tests/test_dd_network_fix_sh.sh
```

若要同时运行真实 ifquery 的解析测试，指定已有工具的位置：

```sh
IFQUERY_TEST_PATH=/usr/sbin/ifquery sh tests/test_dd_network_fix_sh.sh
```

已分别在 dash 和 bash 下通过 56 项测试，包括 4 项真实 Debian ifupdown 0.8.41 ifquery 解析测试。还通过了 ShellCheck 静态检查。未在用户的 VPS 上执行真实重启或一小时后的租约续租验证。
