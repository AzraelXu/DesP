# 多用户共享安装用户指南

本流水线安装在只读共享目录 `/opt/desmond_md_pipeline`：所有用户运行同一份
代码，各自使用独立 `SCH_WORK_ROOT`（默认 `$HOME/desmond_md_work`），
`projects/`、`results/`、`systems/`、`.gpu_locks/` 都在自己目录下。
`/opt/schrodinger2021-2` 及其 license 共享；每个用户用自己的账号提交 PBS
作业，GPU 由 PBS 分配。

详细参数和结果解读见 **[TUTORIAL.md](TUTORIAL.md)**；部署、升级、排错见
**[README.md](README.md)**。

---

## 1. 首次使用

```bash
# 创建默认工作区 $HOME/desmond_md_work
/opt/desmond_md_pipeline/scripts/init_user.sh
```

自定义位置：

```bash
SCH_WORK_ROOT=/path/to/my_desmond_work \
  /opt/desmond_md_pipeline/scripts/init_user.sh
```

想在当前终端目录初始化：

```bash
SCH_WORK_ROOT="$PWD" /opt/desmond_md_pipeline/scripts/init_user.sh
```

必须是绝对路径。`$PWD` 是 bash 内置的绝对当前目录；`$pwd`（小写）不是 bash
变量，会展开为空并回退到默认工作区。传入相对路径时，脚本会把它解析到
`$HOME` 下，而不是当前目录。

`SCH_WORK_ROOT` 判定规则（从高到低）：

1. 显式设置的 `SCH_WORK_ROOT` 或 `PIPELINE_WORK_ROOT`；
2. 代码目录属于当前用户且可写时，使用代码目录；
3. 否则默认 `$HOME/desmond_md_work`。

注意：`SCH_WORK_ROOT=... 命令` 只对该条命令生效，不会留在当前 shell。要在同一终端
的后续命令中生效，先执行一次 `export SCH_WORK_ROOT=/absolute/path`；只赋值不加
`export` 时，子脚本看不到该变量。新终端要重新 export。
`SCH_WORK_ROOT` 必须在登录节点和计算节点都可访问，且不能包含空格、引号、`$`、
反引号或反斜杠；不要以 `root` 身份运行普通用户作业。

从旧版本升级：`WORK_ROOT` 已更名为 `SCH_WORK_ROOT`。新提交不再读取环境里的
`WORK_ROOT`，以免和其他软件冲突；`PIPELINE_WORK_ROOT` 仍作为兼容别名；旧项目
`project.resolved.conf` 里的 `WORK_ROOT` 会在阶段运行时自动迁移，无需手工修改。

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

**Q：可以多人同时用同一个体系名吗？**
可以。只要各自的 `SCH_WORK_ROOT` 不同，输出互不冲突；不要共享 `SCH_WORK_ROOT`。

---

*最后更新：2026-11-16*
