# 开源发布前评估

更新日期：2026-10-19。对象：`install-resource-balancer.sh`；待发布版本为 **v2.8.4**。

**最新结论：已确认的代码发布缺陷已修复；稳定发布仍需 VM 运行验收。** v2.8.3 修复普通卸载和 purge 的 CPU quota 残留，保留管理员配置，清理失败可重试。当前 `main` 的 Linux Bash/ShellCheck 检查及 39 项隔离测试通过，GitHub Actions 的 Python 3.8/3.12 矩阵通过；这不代表已完成真实 systemd/负载/重启/OOM 验收。

## v2.8.4 `rb` 命令入口

- 新增 `/usr/local/bin/rb` 可执行入口，原样转发参数和退出码，支持 sudo、脚本及非交互 shell。
- 安装前检查同名路径；如果已有其他文件占用则拒绝覆盖，并在服务停止前退出。将入口纳入安装暂存、备份和失败回滚。
- 卸载仅删除内容与项目包装脚本完全一致且不是符号链接的 `rb`，保留其他程序创建的同名文件。
- 此版本不改变 CPU/内存控制策略。真实主机安装及控制器负载行为仍须单独验证。

## v2.8.3 卸载配额修复

- 清理范围只包含该 CPU 服务在 `/etc/systemd/system.control`、`/run/systemd/system.control` 中的 `50-CPUQuota.conf`；只移除 `[Service]` 的 `CPUQuota` 设置。
- 纯 quota 文件删除；混合文件用原子替换保留其他行和原模式。其他文件（包括管理员另设的 CPUQuota、CPUWeight）不变。
- 先确认全部服务停止，再清理配额，然后删除程序/unit 并重载。清理部分失败立即报错，保留 CLI，允许同一命令重试。
- 续行、符号链接、非普通文件及无法解码的内容不会被冒险覆盖；保留文件并报错，需管理员检查后重试。不会递归删除整个 drop-in 目录。
- 新增 `tests/test_quota_cleanup.py` 八项检查；最初六项在旧实现失败，修复后全部通过。覆盖普通卸载、purge、两层 quota、混合指令及模式、写入/删除失败重试、重载顺序、续行与符号链接。
- 原有卸载测试也将 quota 路径指向临时目录，避免测试访问真实控制层文件。
- 独立只读审查未发现新的明确高/中严重度问题。

规范文件名已按 systemd v257 官方实现核对：CPUQuota 属性使用设置名 `CPUQuota`，写入函数生成编号 50 的属性 drop-in。参见 [dbus-cgroup.c](https://github.com/systemd/systemd/blob/v257/src/core/dbus-cgroup.c#L1199-L1219) 和 [unit.c](https://github.com/systemd/systemd/blob/v257/src/core/unit.c#L4184-L4245)。这属于源代码依据，不是本机真实服务安装/卸载实测。

## v2.8.2 修复与证据

| 问题 | 修复 | 验证 |
| --- | --- | --- |
| 升级验证完成前无条件删除 30 天前指标 | `METRICS_RETENTION_DAYS=0` 默认关闭清理；缺失、非法值均关闭，正值必须显式设置 | 采集器完整初始化及清理入口默认保留旧样本与异常时间戳；安装后段失败的隔离用例验证数据不变 |
| 重装筛选合法赋值导致旧值复活 | 先读取最后一条同名配置，再严格校验；与采集器使用相同的末项语义 | 30 后跟 nan / 999999 / -1 / 空值，重装后均不启用清理，旧 CSV 不变 |
| 启动失败留下新配置和开机意图 | 启动前保存原配置内容/模式及 disabled / enabled / enabled-runtime；失败先停止新进程，再恢复状态 | 配置写入、enable / disable / start 和即时状态确认失败回归通过；原配置存在/不存在均覆盖 |
| CPU 配额持久状态未恢复 | 保存 `/etc` 与 `/run/systemd/system.control/<unit>.service.d/*.conf`，失败恢复原文件、删除新文件并重载；不把运行时配额写成持久配额 | set-property 部分写入后失败、首次启动新增 quota、持久/运行时不同 quota、无关配置保留用例通过 |
| 启动中断绕过回滚 | 启动事务临时处理 INT / TERM / HUP；恢复期间抑制重复中断，退出恢复原处理器 | CPU/内存 × 三种信号的 6 个真实子进程检查通过，确认恢复状态和 128+signal 退出码 |
| 恢复失败缺少可操作证据 | 保留私有备份目录与 manifest，错误显示备份路径；不在停止失败时覆盖运行进程的配置 | 注入恢复停止失败，确认备份保留且包含旧配置 |

控制器命令故障测试包含 **54 种组合**：CPU 五阶段、内存四阶段 × 三种启用状态 × 原配置存在/不存在。它们包含在一个参数化测试方法中，不能与总测试方法数相加。

## 本轮验证

- v2.8.3 发布标签安装器 SHA-256：`343674926EBD90C72F05D244E1F9B7933FB5872C61D35EF795424AB6E9BC19A5`（历史发布资产）。v2.8.4 发布校验值应以该版本发行附件的 `SHA256SUMS` 为准。
- Debian WSL：Python 3.13.5、ShellCheck 0.10.0、systemd 257.13-1~deb13u1。
- `bash -n install-resource-balancer.sh`：通过。
- 无过滤 `shellcheck install-resource-balancer.sh`：通过。
- `python3 -m unittest discover -s tests -v`：当前 `main` 的 **39 项全部通过，无跳过**；包括四段内嵌 Python 的 compile 检查、真实 POSIX flock、三个 unit 的 systemd-analyze 静态验证。
- Windows Python 3.12.12：37 项检查中 33 项通过，POSIX 锁、systemd-analyze、POSIX 信号及无权限创建符号链接四项按平台跳过；ShellCheck 0.11.0 无过滤检查通过。
- 独立只读审查发现配置末项与 TERM/HUP 边界，修正后复审未发现新的明确高/中严重度问题。
- 所有故障场景均使用临时文件和命令桩；信号仅发送给测试子进程。没有安装、启用或启动真实 Resource Balancer 服务，没有产生实际 CPU/内存负载。

复现命令：

```bash
bash -n install-resource-balancer.sh
shellcheck install-resource-balancer.sh
python3 -m unittest discover -s tests -v
```

测试位于 `tests/test_release.py`、`tests/test_startup_recovery.py`、`tests/test_quota_cleanup.py`。GitHub Actions 的 Python 3.8/3.12 矩阵已通过；Python 3.8 是源码接口下限，远端 CI 通过不替代目标发行版上的运行验收。

## 行为和恢复边界

- **默认不清理 CSV，磁盘占用会持续增长。** 正值 `METRICS_RETENTION_DAYS=1..36500` 为显式授权过期删除，0 为关闭。重启采集器后生效，重装保留有效值。
- 显式启用后，采集器启动时及约每日执行清理；安装失败回滚仍不恢复已授权删除的指标。需要长期留存的数据应另行备份。
- v2.8.2 不能恢复 v2.8.1 已删除的数据。
- 控制器恢复覆盖启动命令修改的配置、启用状态与 systemd 控制层文件；不恢复既有 failed 错误计数或运行期采样、历史、状态文件。
- 恢复失败保留 `/etc/resource-balancer-start-*` 目录，`manifest.json` 记录原路径、模式和对应备份；应先处理恢复错误再重试。SIGKILL、掉电、磁盘损坏不保证自动恢复。
- 启动已确认 active 后进入提交清理阶段，INT/TERM/HUP 暂时忽略；不会因清理阶段终止请求把已提交的启动报告为失败。
- 不带时长或显式 0 仍为永久模式，定时任务不启用开机恢复。目标 80% 的 P95 满足门限仍为 79.5%、恢复 79.0%；它不是已经精确达到 80% P95 的证明。

## 延续的既有修复

v2.8.1 的定时解析、NaN/Inf 校验、安装退出码、停止/卸载失败处理、卸载重试、安装暂存编译与文件回滚、管理锁、路径校验、历史坏样本过滤、unit 排序修正及 MIT 许可证继续保留并纳入回归。

## 尚未完成的发布验收

- [x] 修复卸载/purge 的 CPU quota 残留，保留无关配置并覆盖清理失败重试。
- [x] 修复默认清理旧数据与控制器启动失败后的持久状态恢复。
- [x] 覆盖重复配置、安装后段失败、部分 quota 写入、中断及恢复失败。
- [x] Linux Bash、ShellCheck、四段 Python 编译、39 项检查及 unit 静态校验通过。
- [x] 同步 README、版本和 MIT 许可证；保留远端 CI 配置。
- [ ] 在可丢弃 VM 验证全新安装、2.8.0/2.8.1 升级和真实 systemd/D-Bus 失败恢复。
- [ ] 验证 CPU P95、内存 P95/balance 的实际定时退出、资源释放、永久运行和开机恢复。
- [ ] 验证低/高目标、native 超目标、真实资源限额和长时间收敛。
- [ ] 验证磁盘满、权限错误、损坏配置、SIGKILL/OOM 和掉电后的人工恢复。
- [ ] 实机检查普通卸载、purge，以及 systemd 生成的配额 drop-in 残留。
- [ ] 测量 CSV 扫描与分钟历史重写的长期 I/O 开销，并明确归档策略。
- [ ] 完成声明支持的发行版/Python/systemd/cgroup/架构组合运行验收。
- [x] 建立 GitHub 仓库并执行 Python 3.8/3.12 远端 CI；发行附件提供 SHA-256 校验文件。

三个服务仍以 root 运行，现有 systemd 沙箱不等于降权。发布仓库为 [mrshyi/ResourceBalance](https://github.com/mrshyi/ResourceBalance)，远端检查结果见 [Actions](https://github.com/mrshyi/ResourceBalance/actions)。MIT 版权行为 `Resource Balancer contributors`，未知第三方来源仍需作者确认授权。
