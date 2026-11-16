# 多用户共享安装用户指南

本流水线安装在只读共享目录 `/opt/desmond_md_pipeline`：所有用户运行同一份
代码，各自使用独立 `SCH_WORK_ROOT`。默认值是运行 `init_user.sh` 时的当前
目录（记录在该目录的 `.desmond_work_root` 中）；该目录不可写时回退
`$HOME/desmond_md_work`。`projects/`、`results/`、`systems/`、`.gpu_locks/`
都在自己目录下。`/opt/schrodinger2021-2` 及其 license 共享；每个用户用自己的
账号提交 PBS 作业，GPU 由 PBS 分配。

详细参数和结果解读见 **[TUTORIAL.md](TUTORIAL.md)**；部署、升级、排错见
**[README.md](README.md)**。

---

## 1. 首次使用

```bash
# 在你想放 projects/ 的目录运行（默认工作区就是当前目录）
cd /home/user1/Documents/PSMA_PDC/PDC/test
/opt/desmond_md_pipeline/scripts/init_user.sh
```

init 会创建工作区结构、写入 `.desmond_work_root`，并在 `~/.bashrc` 托管块中
`export SCH_WORK_ROOT` 并配置 `desmond-init`、`desmond-check`、`desmond-smoke`、
`desmond-submit`、`desmond-batch`、`desmond-status`、`desmond-results`。
当前 shell 执行 `source ~/.bashrc`；如果已有旧值，用
`unset SCH_WORK_ROOT && source ~/.bashrc`。别名只在交互 shell 有效。

init 默认更新 `~/.bashrc`，修改前备份为 `~/.bashrc.desmond.bak.<时间戳>`；
不需要改 shell 配置时加 `--no-bashrc`，init 会把 export 和 alias 打印出来
供手工粘贴。

| 快捷命令 | 等价脚本 |
|---|---|
| `desmond-init` | `scripts/init_user.sh` |
| `desmond-check` | `scripts/check_env.sh` |
| `desmond-smoke` | `scripts/submit_smoke.sh` |
| `desmond-submit` | `scripts/submit_system.sh` |
| `desmond-batch` | `scripts/submit_batch.sh` |
| `desmond-status` | `scripts/status.sh` |
| `desmond-results` | `scripts/collect_results.sh` |

自定义位置：

```bash
/opt/desmond_md_pipeline/scripts/init_user.sh --work-root /path/to/my_work
# 或
SCH_WORK_ROOT=/path/to/my_work /opt/desmond_md_pipeline/scripts/init_user.sh
```

`SCH_WORK_ROOT` 判定规则（从高到低）：

1. 显式设置的 `SCH_WORK_ROOT` 或 `PIPELINE_WORK_ROOT`；
2. 从当前目录向上查找最近的 `.desmond_work_root` 标记；
3. 否则 `$HOME/desmond_md_work`。

因此从 `projects/<name>/`、`systems/` 等子目录运行命令也会解析到同一工作区。

注意：

- init 的默认值是运行命令时的当前目录；只有该目录不可写（或路径含空格、
  引号、`$`、反引号、反斜杠）时才回退 `$HOME/desmond_md_work`。
- 在源码树、`$HOME`、`/`、`/tmp` 或已有工作区的子目录里 init，默认会被拒绝；
  确认无误时加 `--force`。
- 重新 init 到不同目录时，`~/.bashrc` 托管块会被替换；旧项目不移动。改变
  已有托管块指向的 root 需要 `--force`。
- `SCH_WORK_ROOT` 必须在登录节点和计算节点都可访问；不要以 `root` 身份运行
  普通用户作业。

从旧版本升级：在旧工作区里重新运行一次 `init_user.sh` 补上
`.desmond_work_root`；也可以继续显式 `export SCH_WORK_ROOT=<旧路径>`。
`WORK_ROOT` 已更名为 `SCH_WORK_ROOT`；`PIPELINE_WORK_ROOT` 仍作为兼容别名；
旧项目 `project.resolved.conf` 里的 `WORK_ROOT` 会在阶段运行时自动迁移。
旧 `.done` 没有 `RUN_ID` 也能被 `status.sh` 正确识别（回退比较 `JOBID`），
不需要手工修改。

---

## 2. 配置自己的体系

```bash
cp /opt/desmond_md_pipeline/systems/example.conf.example \
   "$SCH_WORK_ROOT/systems/my_sys.conf"
vi "$SCH_WORK_ROOT/systems/my_sys.conf"
```

最少填写：

```bash
SYSTEM_NAME="my_sys"
INPUT_STRUCTURE="/absolute/path/to/complex.pdb"
RECEPTOR_ASL="chain A"
LIGAND_ASL="chain B"
```

输入格式：

| 变量 | 接受的格式 | 行为 |
|---|---|---|
| `INPUT_STRUCTURE` | PDB、MAE、`.maegz` | 先运行 PrepWizard，再建系 |
| `PREPARED_STRUCTURE` | MAE、`.maegz` | 跳过 PrepWizard，直接建系 |

- 两者只设置一个；若都设置，**`PREPARED_STRUCTURE` 优先**，冻结配置会清空
  `INPUT_STRUCTURE`。相对路径按 `.conf` 所在目录解析。
- 可选 `PROJECT_DIR`（默认 `$SCH_WORK_ROOT/projects/<SYSTEM_NAME>`）；路径会写入
  PBS 脚本，必须纯 ASCII、无空格/引号。

---

## 3. 检查结构和 ASL

```bash
export SCHRODINGER=/opt/schrodinger2021-2

$SCHRODINGER/run python3 \
  /opt/desmond_md_pipeline/scripts/inspect_structure.py \
  --structure /absolute/path/to/complex.pdb \
  --receptor-asl "chain A" \
  --ligand-asl "chain B" \
  --align-asl "chain A and backbone and not (atom.ele H)" \
  --check
```

输出会列出每条链的原子/残基数、HET 基团、水、离子和各 ASL 的原子数。任何
ASL 选中 0 个原子时 `--check` 会非零退出。配体通常用独立链（`chain B`）或
残基名（`res.ptype LIG`）。

---

## 4. 检查、提交、监控

```bash
# 环境检查（登录节点；无 FAIL 即可）
/opt/desmond_md_pipeline/scripts/check_env.sh

# GPU/license/写权限冒烟（PBS 作业，约 10 分钟）
/opt/desmond_md_pipeline/scripts/submit_smoke.sh

# 先看计划和渲染出的 PBS；dry-run 也会写项目目录和冻结配置
/opt/desmond_md_pipeline/scripts/submit_system.sh \
  "$SCH_WORK_ROOT/systems/my_sys.conf" --dry-run

# 正式提交：prep(CPU) -> min(1 GPU) -> md(1 GPU) -> analysis / mmgbsa(CPU)
/opt/desmond_md_pipeline/scripts/submit_system.sh \
  "$SCH_WORK_ROOT/systems/my_sys.conf"

# 监控与汇总
/opt/desmond_md_pipeline/scripts/status.sh my_sys
/opt/desmond_md_pipeline/scripts/collect_results.sh
```

`status.sh` 显示当前阶段、elapsed/ETA 和当前 run 的 WARN/FATAL，不再打印完整
队列和节点/GPU 表；需要时手动运行 `qstat -u "$USER"`。

示例（MD 运行中）：

```
Project : my_sys
Run     : 20261116_152012_46171 (submitted 2026-11-16 15:20)
Step    : md (4/6) -- running (PBS 995), elapsed 2h 14m
Progress: 432.0 / 300000.0 ps (0.1%), avg rate 250.1 ns/day (avg10)
ETA     : ~1d 04h; PBS walltime left 3d 21h
Warnings: 1 in this run
  [WARN] ...
Errors  : none
```

- `Warnings`/`Errors` 只统计本次提交（`SUBMITTED_AT`）之后的记录；旧运行的
  警告需要手动 `grep '^\[WARN\]' logs/pipeline.log`。
- MD 的引擎日志可能还在 scratch、尚未回传到项目目录；此时 ETA 显示
  `unknown (engine log not in project dir yet)`，只给 PBS walltime 余量。
- 失败阶段会显示 `FAILED`、`Blocked : ...` 以及 PBS/阶段日志尾部。
- 无参数时扫描 `$SCH_WORK_ROOT/projects/` 下所有项目；参数也可以是项目目录
  绝对路径。

提交必须在**登录节点**执行；脚本检测到 `PBS_JOBID` 会拒绝。smoke 输出在
`$SCH_WORK_ROOT/projects/_smoke/`。

---

## 5. 输出位置

| 内容 | 路径 |
|---|---|
| 项目输出 | `$SCH_WORK_ROOT/projects/<SYSTEM_NAME>/` |
| PBS 标准输出 | `$SCH_WORK_ROOT/projects/<SYSTEM_NAME>/logs/pbs/` |
| 阶段详细日志 | `$SCH_WORK_ROOT/projects/<SYSTEM_NAME>/logs/` |
| 单体系结果 | `$SCH_WORK_ROOT/projects/<SYSTEM_NAME>/results/` |
| 跨体系汇总 | `$SCH_WORK_ROOT/results/` |

`collect_results.sh` 只汇总当前用户 `SCH_WORK_ROOT` 下的项目。

---

## 6. 共享使用规则

- `/opt/desmond_md_pipeline` 由管理员维护，普通用户只读；不要尝试写入。
- `SCH_WORK_ROOT` 属于当前用户；不要与其他人共享同一个 `SCH_WORK_ROOT`。
- 不要把 license、密钥或未公开结构放进共享代码目录。
- 每个用户用自己的账号提交 PBS 作业；每个 min/MD 只申请 1 张 GPU。

---

## 7. 常见问题

**Q：运行时报 “Permission denied” 写 `/opt/desmond_md_pipeline`？**
`SCH_WORK_ROOT` 被错误地设成了代码目录。`unset SCH_WORK_ROOT`，或显式设置一个有
写权限的目录。

**Q：`check_env.sh` 报 license FAIL？**
确认 `/opt/schrodinger2021-2/license` 可读，或由管理员配置
`SCHRODINGER_LICENSE_FILE` / `LM_LICENSE_FILE`。不要复制 license 到共享目录。

**Q：作业提交后找不到输出？**
看 `$SCH_WORK_ROOT/projects/<name>/logs/pbs/*.out` 和 `logs/*.log`。

**Q：重新 init 到别的目录后，旧项目去哪了？**
旧项目仍留在旧工作区，不会移动。可以用
`/opt/desmond_md_pipeline/scripts/status.sh /旧工作区/projects/<name>` 查看，
或继续在旧工作区运行命令。新工作区只影响之后的提交。

**Q：`source ~/.bashrc` 后还是旧 root / 别名不生效？**
如果当前 shell 已经有 `SCH_WORK_ROOT`，托管块不会覆盖它；执行
`unset SCH_WORK_ROOT && source ~/.bashrc`。别名只在交互 bash 中生效，
`ssh host desmond-status` 或脚本里请用绝对路径或显式 `export`。

**Q：`status.sh` 为什么没有 ETA？**
queued/running 的非 MD 阶段没有可靠进度源，只显示 elapsed 和 PBS walltime
余量；MD 的引擎日志如果还在 scratch、没回传到项目目录，也会显示 ETA unknown。
作业结束后日志回传，再运行 status 即可看到 chemical time 和速率。

**Q：`status.sh` 的警告/错误包含旧运行吗？**
不包含。它按当前 `jobs.env` 的 `SUBMITTED_AT` 过滤，只显示本次提交之后的
`WARN`/`FATAL`；需要历史记录时直接查看 `logs/pipeline.log`。

**Q：`status.sh` 不显示节点/GPU 了吗？**
是的。需要时手动运行 `qstat -u "$USER"`、`pbsnodes -a` 或
`qstat -f -1 <jobid>`。

**Q：可以多人同时用同一个体系名吗？**
可以。只要各自的 `SCH_WORK_ROOT` 不同，输出互不冲突；不要共享 `SCH_WORK_ROOT`。

---

*最后更新：2026-11-16*
