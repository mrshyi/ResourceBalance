# Resource Balancer

Linux 主机资源监控与可选 CPU / 内存合成负载控制工具。当前安装脚本版本为 **2.8.4**，使用 Bash、Python 标准库和 systemd，无需 pip 依赖。

> 发布状态：已修复默认清理历史数据、启动失败状态恢复和卸载配额残留等已确认问题，并采用 MIT 许可证；真实负载、重启恢复和 OOM 场景仍需在可丢弃 VM 验收。完整验证范围见 [发布评估](RELEASE_ASSESSMENT.md)。

## 功能与边界

- **采集器**：持续记录整机 CPU、内存和工具管理的内存量，默认每 60 秒写入 CSV。
- **CPU 控制器**：基于本地滚动 7 天 P95 决定是否添加合成负载；达到阈值后停止补充负载。
- **内存控制器**：默认采用 P95 策略；`balance` 模式持续分配、释放内存，向整机实时使用率目标靠近。
- **管理 CLI**：查看状态、历史、健康信息及日志，控制服务并卸载。

这是会主动消耗 CPU 和内存的工具。控制器只能减少自身产生的负载，不能降低其他应用的资源使用量，也不是业务进程的资源调度器或完整的硬件诊断工具。运行会增加资源竞争、耗电和潜在费用，应先在可丢弃的测试机验证。

P95 是现有本地样本的插值百分位数，并包含当前未完成分钟的临时估计；不足 7 天时依然会参与控制。控制器约每 60 秒保存一次分钟均值，只有控制器运行时才积累对应 P95 历史。采集器 CSV 与控制器历史是两套数据，`history` 输出不等同于控制器当前 P95。覆盖率按最早样本到现在的时间跨度估计，不能证明采样连续。

P95 模式补充负载时，瞬时目标为 `min(80%, 目标 + 5 个百分点)`。进入满足状态的阈值为 `min(79.5%, 目标 + 0.5 个百分点)`；恢复阈值为 `min(目标 - 0.5 个百分点, 进入阈值 - 0.5 个百分点)`。上限附近会降低门限，确保控制器能在补充负载死区之前满足条件并保留滞回。**目标不是瞬时使用率上限，也不是精确达标保证。**

脚本中的 OCI 提示只表示本地估计不能替代云平台判断；本项目不保证任何云平台的保留、回收或计费结果。使用前应自行核对服务商条款。

## 环境要求

- Linux 主机，具有 `/proc/stat`、`/proc/meminfo`，并由 systemd 管理服务。
- Bash、`/usr/bin/python3`、`systemctl`、`journalctl`、util-linux 的 `flock` 及常用 GNU 系统命令。
- Python 代码使用 `statistics.fmean`，需要 Python 3.8 或更高版本；此为源码接口下限，不是已验证的兼容矩阵。
- root 权限；普通用户安装时需要可用的 `sudo`。
- systemd/cgroup 需要支持脚本使用的内存限制、CPU 权重/配额及服务隔离选项。

当前没有已验证的发行版、systemd 版本或 CPU 架构支持矩阵。Windows、macOS、没有 systemd 的容器不属于当前运行目标。

## 安装

项目地址：[mrshyi/ResourceBalance](https://github.com/mrshyi/ResourceBalance)。在具有 `curl` 的测试 Linux 主机运行下面一行，下载完整的 v2.8.4 脚本、校验 SHA-256 后安装（普通用户会提示 sudo 密码）：

```bash
(set -e; f=$(mktemp); trap 'rm -f "$f"' EXIT; curl -fsSL https://raw.githubusercontent.com/mrshyi/ResourceBalance/v2.8.4/install-resource-balancer.sh -o "$f"; printf '%s  %s\n' b6962f3b6a873d2215e4e13f428ba614fb9253963fd6baedc060c2851b535927 "$f" | sha256sum -c -; bash "$f")
```

v2.8.4 为预发布候选，新增 `rb` 命令入口，其他功能和 `resource-balancer` 完全相同。安装默认仅启动采集器，CPU/内存合成负载需要另行显式启动。安装前建议先审阅脚本；远端自动检查见 [GitHub Actions](https://github.com/mrshyi/ResourceBalance/actions)。

先下载并审阅本目录的 `install-resource-balancer.sh`，确认来源和完整性，然后在测试 Linux 主机执行：

```bash
bash -n install-resource-balancer.sh
sudo bash install-resource-balancer.sh

resource-balancer version
systemctl is-active resource-balancer-collector
resource-balancer health
resource-balancer status
```

安装器会写入 `/usr/local`、`/etc`、`/var/lib`，并自动启用、启动采集器。全新安装不会主动启动 CPU 和内存控制器。采集器等待一个采样周期才写首条记录，初次 `health` 出现 `WARMING UP` / 无数据应结合日志判断。

安装器会先在私有临时目录生成并编译四段 Python，再备份被替换文件、停止服务并替换文件。替换、服务重启或采集器验证失败时尝试恢复旧文件和服务启用/运行状态；恢复不完整会返回非零并显示保留备份的路径。SIGKILL、掉电、磁盘损坏和不可停止的服务不能保证自动恢复，重装前仍应备份配置与数据。

仅支持全新安装和规范布局的 v2.8.x 重装。重装保留控制器配置和历史，尝试恢复原有服务启用/运行状态，并保留有效的 `SAMPLE_INTERVAL`、`METRICS_RETENTION_DAYS`；运行状态会随进程重启更新，采集器配置文件的其他自定义内容会被重写。检测到脚本列出的旧版路径时会拒绝安装；当前目录未提供提示中提及的历史升级安装器。安装器会拒绝符号链接、异常路径类型、非 root 拥有或组/其他用户可写的安装路径；应调查路径来源，不要为了通过检查递归修改系统目录权限。

## 查看状态和历史

v2.8.4 起可用 `rb` 代替 `resource-balancer`，全部子命令和参数保持一致，例如 `rb status`、`rb memory status`、`sudo rb cpu stop`。该入口是系统可执行文件，支持 sudo 和非交互 shell。若 `/usr/local/bin/rb` 已被其他程序占用，安装器会拒绝覆盖；卸载会移除本工具创建的入口。

```bash
resource-balancer help
resource-balancer inspect
resource-balancer cpu status
resource-balancer memory status
resource-balancer history 1h
resource-balancer history 24h
resource-balancer history 7d

sudo resource-balancer logs
sudo resource-balancer logs cpu
sudo resource-balancer logs memory
```

`logs` 持续跟踪 journal，按 Ctrl+C 退出。CPU 百分比以整机逻辑 CPU 总容量为基准；内存使用率为 `(MemTotal - MemAvailable) / MemTotal`。“native” 是减去工具管理负载后的估计值，不是对业务进程的精确归因。

## 启动与停止可选负载

**不带 `--duration` 会持续消耗资源并启用开机恢复。** 建议先在测试机使用带时长的命令，观察状态和日志，再决定是否启用永久模式。

目标参数的设计范围为 5–80%；CPU 只支持 P95，内存默认 P95。已经运行时再次执行 `test` 不会修改目标，应先停止。

```bash
# 定时模式：10 分钟后退出，不启用开机恢复。
sudo resource-balancer cpu test --target 25 --duration 10m
sudo resource-balancer memory test --target 25 --duration 10m

# 定时结束前如需更换模式，先执行对应的 stop。
# 时长支持整数秒或 s/m/h，范围 10 秒至 24 小时；0 表示永久。

# 永久模式：需要明确执行 stop 才停止，并启用开机恢复。
# sudo resource-balancer cpu test --target 25
# sudo resource-balancer memory test --target 25

# 内存实时填充模式；与默认内存 P95 模式二选一。
# sudo resource-balancer memory test --target 50 --mode balance

sudo resource-balancer cpu stop
sudo resource-balancer memory stop

# 可额外检查服务状态。
systemctl is-active resource-balancer-cpu
systemctl is-active resource-balancer-memory
```

停止成功时，`systemctl is-active` 应输出 `inactive` 并返回非零状态。CLI 会检查 systemctl 结果和服务停止状态，失败时保留配置及状态并返回非零。若停止失败，直接检查：

```bash
sudo systemctl disable --now resource-balancer-cpu resource-balancer-memory
systemctl status resource-balancer-cpu resource-balancer-memory --no-pager
```

控制器启动前会保存原配置、开机启用状态及 CPU 的持久/运行时 quota 文件。写入、启用、启动或即时状态确认失败时，先停止新进程，再恢复文件和启用状态；INT/TERM/HUP 中断启动也执行恢复。若恢复失败，错误会给出 `/etc/resource-balancer-start-*` 备份目录，其中 `manifest.json` 记录原路径、模式及备份文件。先处理该恢复错误，再重试启动；SIGKILL 和掉电不保证自动恢复。

内存服务配置 `MemoryHigh=82%`、`MemoryMax=85%`；CPU 通过 CLI 设置按整机容量换算的配额，名义上限为 `min(85%, 目标 + 10 个百分点)`。这些限制作用于工具服务，并不为其他业务预留固定资源，也不能保证主机不会 OOM。CPU 服务基础 unit 没有 `CPUQuota`，不要跳过 CLI 直接启动未经配置的服务。

## 采集配置与数据

| 路径 | 内容 |
| --- | --- |
| `/usr/local/bin/resource-balancer` | Python CLI |
| `/usr/local/lib/resource-balancer/` | `collector.py`、`memory.py`、`cpu.py` |
| `/etc/resource-balancer.conf` | `SAMPLE_INTERVAL=60`（秒，实际最小 10 秒）；`METRICS_RETENTION_DAYS=0`（默认关闭自动清理） |
| `/etc/resource-balancer-{cpu,memory}.conf` | 控制器目标和持续时间；内存还保存模式 |
| `/var/lib/resource-balancer/metrics.csv` | UTC 时间戳、CPU/内存使用率及 managed/native 内存字段 |
| `/var/lib/resource-balancer/*-p95-history.jsonl` | 控制器滚动历史，保留最近 7 天 |
| `/var/lib/resource-balancer/memory-managed-kb` | 工具管理的内存计数 |
| `/var/lib/resource-balancer/{cpu,memory}-state` | 控制器 JSON 运行状态 |
| `/etc/systemd/system/resource-balancer-*.service` | 三个服务 unit |

修改采集间隔后重启采集器：

```bash
sudoedit /etc/resource-balancer.conf
sudo resource-balancer service restart
```

`service start|stop|restart|status` 只管理采集器，不会停止控制器。普通 `stop` 会删除相应控制器配置及运行状态，保留历史。

**从 v2.8.2 起默认保留全部 CSV 数据，不自动清理。** `METRICS_RETENTION_DAYS=0`、缺失或非法值均关闭清理。重复配置按最后一项处理；重装不会从更早的合法值恢复清理。升级不会恢复 v2.8.1 已删除的数据。

如需自动保留 30 天，请先备份，再编辑 `/etc/resource-balancer.conf`，将该项改为 `METRICS_RETENTION_DAYS=30`，然后执行 `sudo resource-balancer service restart`。有效正值为 1–36500；明确启用后，采集器启动时、之后约每 24 小时会删除过期样本。重装会保留这一显式设置，安装失败回滚也不会恢复已清理的指标数据。

清理采用流式读取和临时文件替换，需要额外磁盘空间。默认不清理时文件持续增长，应自行监控磁盘并制定归档策略。状态和健康查询只保留最新有效样本，历史查询只保留所选时间窗口，但都需要扫描 CSV。采集数据会暴露主机资源使用模式，分享前请审阅。

安装和 root 管理命令共享 `/run/resource-balancer.lock`，并发操作会立即失败；只读状态查询不需要这个锁。服务仍以 root 运行，现有 systemd 沙箱不等同于降权。

## 卸载

```bash
# 删除 CLI、工作程序与服务；保留配置、指标、历史和状态。
sudo resource-balancer uninstall

# 或：同时删除配置和全部历史数据，不可恢复，当前没有交互确认。
# sudo resource-balancer uninstall --purge
```

卸载前备份需要保留的数据。卸载先确认三个服务停止，再删除程序与 unit；命令失败返回非零，不会报告完成。CLI 最后删除，便于中途失败后重试。普通卸载后的残留配置不会让全新安装自动恢复之前的控制器启用状态，重新启用需要显式执行 `test`。

普通卸载和 `--purge` 都会清理 `/etc/systemd/system.control`、`/run/systemd/system.control` 下该 CPU 服务的 `50-CPUQuota.conf` 中的 `CPUQuota` 设置。这是工具管理的配额位置；其他文件以及同文件中的其他指令和模式会保留，再重载 systemd。多行续行、符号链接或无法读取的配置会使卸载失败，保留 CLI 供检查后重试。管理员 drop-in、手工备份和启动失败恢复备份不会被整目录删除。

## 故障排查

```bash
sudo systemctl status resource-balancer-collector --no-pager
sudo journalctl -u resource-balancer-collector -n 100 --no-pager
sudo journalctl -u resource-balancer-cpu -n 100 --no-pager
sudo journalctl -u resource-balancer-memory -n 100 --no-pager
```

- `NameError: parse_duration`：说明仍在运行旧版 CLI，检查 `resource-balancer version` 和安装日志。
- 采集器正常但无样本：等待至少一个采样周期，检查目录写权限、磁盘空间和 journal。
- 控制器反复重启：检查配置、Python traceback、OOM 和 systemd 资源限制；先停止服务再排查。
- CLI 退出码：`0` 成功（包括采集预热），`1` 执行失败或健康降级，`2` 参数错误。启动阶段 INT/TERM/HUP 中断并完成恢复后分别返回 `130`/`143`/`129`。预热是否允许上线应由使用方另行判断。

## 开发与发布验证

项目采用单文件安装器，内嵌四段 Python 程序和三个 systemd unit，没有 C++/Qt 编译步骤。回归测试只使用 Python 标准库，提取内嵌程序并用临时目录和命令桩验证，不安装服务、不启动负载。

```bash
# 仅做 Bash 语法检查，不执行安装。
bash -n install-resource-balancer.sh

# 开发环境安装 ShellCheck 后运行。
shellcheck install-resource-balancer.sh
python3 -m unittest discover -s tests -v
```

GitHub Actions 配置见 [.github/workflows/check.yml](.github/workflows/check.yml)，包含 Bash 语法、ShellCheck、Python 3.8/3.12 回归检查；仓库推送后才会触发，不能将配置存在当作 CI 已通过。安装器在服务变更前运行 `python3 -m py_compile`，但语法编译不能替代集成测试。发布前还需完成 [评估中的验收清单](RELEASE_ASSESSMENT.md#发布前验收清单)。报告问题时提供发行版、Python/systemd 版本、命令、完整错误和脱敏日志。

## 许可证

采用 [MIT License](LICENSE)，版权行使用 `Resource Balancer contributors`。提交代码前请确认有权按此许可证授权；本目录的许可证不能替代对未知第三方来源的核查。
