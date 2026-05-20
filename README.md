# 魔方云实例资源实时监测脚本使用文档

`mfy-instance-usage.sh` 是一个用于 KVM/libvirt 宿主机的实例资源监测脚本。它通过 `virsh` 采集虚拟机 CPU、内存、网络收发速率，并以表格形式展示资源占用最高的实例。

脚本适合在魔方云、KVM、libvirt 环境中快速排查实例带宽、CPU、内存占用情况。

## 功能概览

- 查看运行中实例的 CPU、内存、下行、上行、总网速。
- 支持单次查看和实时刷新。
- 支持按 CPU、内存、下行、上行、总网速排序。
- 支持限制显示前 N 个高占用实例。
- 支持自动适配 `virsh domstats` 的不同采集能力。
- 支持快速 vCPU 缓存模式，减少大量实例场景下的启动等待。
- 支持固定实例名称列宽，避免宽屏终端输出间距过大。

## 运行环境

脚本需要在 Linux 宿主机上运行，并要求宿主机可正常访问 libvirt。

必须依赖：

```bash
virsh
awk
sort
date
tput
mktemp
cat
```

可选依赖：

```bash
timeout
```

如果系统存在 `timeout`，脚本会自动为单个 `virsh` 命令加超时保护，避免某条命令卡住整个监控。

## 快速开始

一键下载 [mfy-instance-usage.sh](https://github.com/jia42520/mfyjk/blob/main/mfy-instance-usage.sh)，添加执行权限并启动实时监测：

```bash
curl -fsSL -o mfy-instance-usage.sh https://raw.githubusercontent.com/jia42520/mfyjk/main/mfy-instance-usage.sh
chmod +x ./mfy-instance-usage.sh
./mfy-instance-usage.sh
```

实时查看前 20 个总网速最高的运行中实例：

```bash
./mfy-instance-usage.sh --watch --interval 1 --limit 20
```

单次查看：

```bash
./mfy-instance-usage.sh --sort net --limit 20
```

按 CPU 占用排序：

```bash
./mfy-instance-usage.sh --watch --sort cpu --limit 20
```

按内存占用排序：

```bash
./mfy-instance-usage.sh --watch --sort mem --limit 20
```

## 输出字段说明

示例输出：

```text
ID       实例          状态       CPU       内存           下行          上行          总网速
234      kvm359        running    28.12%    7.75GB         1.49MB/s     3.28MB/s     4.77MB/s
```

字段含义：

| 字段 | 说明 |
| --- | --- |
| ID | 脚本内部展示编号，来自当前实例列表顺序 |
| 实例 | 虚拟机实例名称 |
| 状态 | 实例状态，例如 `running`、`paused`、`shutoff`、`unknown` |
| CPU | 采样间隔内的平均 CPU 占用 |
| 内存 | 当前内存占用 |
| 下行 | 实例网卡接收速率 |
| 上行 | 实例网卡发送速率 |
| 总网速 | 下行 + 上行 |

顶部的“母鸡带宽”表示宿主机非虚拟网卡的总收发速率：

```text
母鸡带宽 | 下行: 15.55MB/s | 上行: 13.04MB/s | 总: 28.59MB/s
```

脚本会排除常见虚拟网卡，例如 `lo`、`virbr`、`vnet`、`tap`、`docker`、`veth` 等。

## CPU 计算说明

脚本通过两次采样之间的 CPU 累计时间差计算 CPU 占用：

```text
CPU% = CPU时间增量 / 实际采样秒数 / vCPU数量 * 100
```

注意：

- 脚本使用实际采样间隔，而不是简单使用配置的 `--interval`。
- 如果 `virsh domstats` 执行较慢，实际采样间隔会自动变长，计算结果会更接近真实值。
- 默认 `fast` vCPU 模式优先保证加载速度，如果某些宿主机无法批量返回 vCPU，CPU 可能不如 `exact` 模式精确。
- 如果 CPU 看起来异常高，可以用下面命令检查实例 vCPU：

```bash
virsh vcpucount kvm001
```

## 交互菜单

菜单支持：

- 单次查看。
- 实时监测。
- 修改排序方式。
- 修改刷新/采样间隔。
- 切换实例范围。
- 修改显示数量。

## 状态与异常提示

顶部状态示例：

```text
模式: full
```

如果连续采集到空结果，会显示：

```text
模式: full/2次空结果
```

这表示 `virsh domstats` 连续返回空数据，常见原因包括：

- libvirt 瞬时繁忙。
- 实例数量较多，`virsh` 响应慢。
- 当前用户权限不足。
- 当前宿主机的 `virsh domstats` 参数兼容性不好。

可以尝试：

```bash
./mfy-instance-usage.sh --watch --stats-mode basic
./mfy-instance-usage.sh --watch --timeout 8
```

## 常见问题

### 提示缺少依赖命令

例如：

```text
缺少依赖命令: virsh
```

说明当前系统缺少对应命令，或命令不在 `PATH` 中。需要先安装 libvirt 工具或修正环境变量。

### 未发现实例

可能原因：

- 当前没有运行中实例。
- 默认只显示运行中实例。
- 当前用户没有权限访问 libvirt。
- `virsh list --name` 返回为空。

可以查看全部实例：

```bash
./mfy-instance-usage.sh --all
```

也可以手动检查：

```bash
virsh list --all
```

### CPU 全是 0

可能原因：

- `virsh domstats` 没有返回 CPU 累计时间。
- 采样间隔太短。
- 实例确实没有明显 CPU 活动。

可以尝试：

```bash
./mfy-instance-usage.sh --watch --interval 3 --stats-mode basic
```

### CPU 看起来偏高

先检查 vCPU：

```bash
virsh vcpucount <实例名>
```

如果默认 fast 模式无法正确获取 vCPU，可以使用 exact 模式：

```bash
./mfy-instance-usage.sh --watch --vcpu-mode exact --sort cpu
```

### 输出列间距不合适

调整实例名称列宽：

```bash
./mfy-instance-usage.sh --watch --name-width 10
./mfy-instance-usage.sh --watch --name-width 16
```

### 实时模式退出

按：

```text
Ctrl+C
```

如果从交互菜单进入实时模式，退出实时监测后会返回菜单。
