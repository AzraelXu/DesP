# Desmond 蛋白–配体 MD 流水线管理员手册

本目录是管理员维护的共享安装（推荐 `/opt/desmond_md_pipeline`）。流水线把
PrepWizard、Desmond 建系、最小化、生产 MD、轨迹分析和 MM-GBSA 拆成独立的
PBS 作业，用 `afterok` 依赖串联：

```
蛋白–配体复合物（PDB/MAE/maegz）
        │
        ▼
[prep]  CPU      PrepWizard（可选）+ Desmond 建系
        │ afterok
        ▼
[min]   1 GPU    最小化 / 低温柔化
        │ afterok
        ▼
[md]    1 GPU    5 段 NPT 弛豫 + 生产 MD
        │ afterok
        ├──────────────► [analysis] CPU  对齐 + RMSD + 出图
        └──────────────► [mmgbsa]   CPU  MM-GBSA
```

关键设计：

- 每个阶段一个 PBS 作业，资源、日志、依赖都写在 PBS 层；
- GPU 作业内部用 `multisim -HOST localhost -WAIT`，不依赖、也不修改站点的
  `schrodinger.hosts`；
- 每个 min/MD 只申请 1 张 GPU，每节点 GPU 数只影响并发；
- 阶段化、幂等、提交时冻结配置；输入/参数变化由签名检测。

## 文档角色

| 文档 | 读者 | 内容 |
|---|---|---|
| `README.md`（本文） | 管理员 | 部署、配置、PBS 内部设计、升级、排错、验收 |
| `TUTORIAL.md` | 普通用户 | 详细使用教程、参数、输出与结果解读 |
| `MULTIUSER.md` | 普通用户 | 共享安装快速上手 |

维护约定：用户文档只保留使用相关内容；部署、内部实现、验证记录和排错细节
放在本文。三份文档的最后更新时间应同步。

---

## 1. 系统要求与已验证版本

已验证环境：

- Schrödinger 2021-2（Desmond 6.6 / multisim 3.8.5），安装于
  `/opt/schrodinger2021-2`；
- Torque PBS，支持 `-l nodes=1:ppn=N[:gpus=1]` 语法和 `afterok` 依赖；
- `qsub`、`qstat`、`qdel`、`pbsnodes` 在登录节点 PATH 中；
- GPU 节点有 NVIDIA 驱动和 `nvidia-smi`；
- Schrödinger 自带 Python 3.8 及 pandas、matplotlib、openpyxl、Desmond API；
- license 至少包含 `DESMOND_MAIN`、`DESMOND_GPGPU`；启用 MM-GBSA 时还需要
  `PRIMEX_MAIN`。

要求：

- 登录节点和计算节点共享可写的 `SCH_WORK_ROOT`、`$HOME/.schrodinger` 和 PBS 日志
  路径；
- PBS 脚本必须纯 ASCII（渲染后自动检查）；
- 代码目录、项目路径、`SYSTEM_NAME` 不能包含空格、引号、`$`、反引号或
  反斜杠。

---

## 2. 部署到 `/opt`

### 2.1 复制代码

从源码目录同步（排除运行产物）：

```bash
sudo mkdir -p /opt/desmond_md_pipeline
sudo rsync -a --delete \
  --exclude projects/ --exclude results/ --exclude .gpu_locks/ \
  --exclude '*.bak.*' \
  <source-dir>/ /opt/desmond_md_pipeline/
```

注意：PBS 作业在运行时会从 `PIPELINE_ROOT` 读取阶段脚本和 `scripts/lib/*.sh`。
如果队列里还有 `Q/R/H` 作业，升级会改变在途作业的代码行为（冻结的
`project.resolved.conf` 只固定科学参数）。部署前先确认 `qstat -u "$USER"`
没有在途作业，或明确接受在途作业使用新版脚本。

推荐使用“版本目录 + 软链接”，便于回滚：

```bash
/opt/desmond_md_pipeline-20261116/
/opt/desmond_md_pipeline -> /opt/desmond_md_pipeline-20261116
```

### 2.2 所有权与权限

- 代码目录归 `root:root`，普通用户只读；
- 保持脚本可执行位（`rsync -a` 会保留；必要时
  `sudo chmod 755 /opt/desmond_md_pipeline/config.sh /opt/desmond_md_pipeline/scripts/*.sh`）；
- 文档和模板可以是 `644`；
- 不要把 license 文件、密钥或用户结构放进共享代码目录。

普通用户的运行输出全部写到自己的 `SCH_WORK_ROOT`，代码目录不产生
`projects/`、`results/` 或 `.gpu_locks/`。

### 2.3 管理员自检

```bash
/opt/desmond_md_pipeline/scripts/check_env.sh
```

登录节点无 GPU 会有一个预期 WARN；不应有 FAIL。

---

## 3. 管理员配置（`config.sh` 全量参考）

`config.sh` 是机器/PBS/科学默认参数。加载顺序：

1. `config.sh` 默认值；
2. 环境变量（`config.sh` 使用 `${VAR:-default}`，已设置的非空环境变量优先）；
3. `systems/<name>.conf`（覆盖以上）；
4. 提交时冻结的 `$SCH_WORK_ROOT/projects/<name>/project.resolved.conf`：
   PBS 作业只读它。

命令行 `--from/--force/--dry-run` 只控制阶段选择，不覆盖科学参数。

### 3.1 工作区与机器

| 变量 | 默认 | 说明 |
|---|---|---|
| `SCH_WORK_ROOT` / `PIPELINE_WORK_ROOT` | 见下 | 用户工作区 |
| `GPU_LOCK_DIR` | `$SCH_WORK_ROOT/.gpu_locks` | nvidia-smi 回退锁目录 |
| `SCHRODINGER` | `/opt/schrodinger2021-2` | Schrödinger 安装路径 |
| `SCHRODINGER_LICENSE_FILE` / `LM_LICENSE_FILE` | 空 | license server 时设置 |
| `SCHRODINGER_HOSTS` | 空 | 留空使用默认 hosts；空值会被 `unset` |
| `QSUB` / `QSTAT` / `QDEL` / `PBSNODES` | 同名命令 | 不在 PATH 时填绝对路径 |

`SCH_WORK_ROOT` 判定：

1. 显式 `SCH_WORK_ROOT` 或 `PIPELINE_WORK_ROOT`；
2. 从当前目录逐级向上查找最近的 `.desmond_work_root` 标记；标记所在目录就是
   工作区（`init_user.sh` 在运行目录创建该标记）；
3. 否则使用 `$HOME/desmond_md_work`。

`init_user.sh` 的默认工作区是**运行命令时的当前目录**；只有该目录不可写（或
路径含空格等不支持字符）时才回退到 `$HOME/desmond_md_work`。`--force` 用于
显式允许在源码树、`$HOME`、`/`、`/tmp` 等位置初始化，或替换 `~/.bashrc` 中
指向其他 root 的托管块。init 还会在 `~/.bashrc` 写入托管块，导出
`SCH_WORK_ROOT` 并配置 `desmond-init`、`desmond-check`、`desmond-smoke`、
`desmond-submit`、`desmond-batch`、`desmond-status`、`desmond-results`、
`desmond-systems` 别名。

从旧版本升级：在旧工作区里重新运行一次 `init_user.sh` 即可补上
`.desmond_work_root` 标记（项目和输出不动）；也可以继续显式
`export SCH_WORK_ROOT=<旧路径>`。

命名迁移：`WORK_ROOT` 已更名为 `SCH_WORK_ROOT`。新提交不再读取环境变量
`WORK_ROOT`（避免与其他软件冲突）；`PIPELINE_WORK_ROOT` 保留为弃用别名。
旧项目的 `project.resolved.conf` 由 `load_project_env` 自动迁移，无需手工修改；
`FREEZE_VARS` 现在冻结 `SCH_WORK_ROOT`。

### 3.2 PBS 资源

| 变量 | 默认 | 说明 |
|---|---|---|
| `PBS_QUEUE` | `batch` | 队列名；空则省略 `#PBS -q` |
| `PBS_PPN_PREP` | 4 | prep CPU 核数 |
| `PBS_PPN_ANALYSIS` | 1 | analysis CPU 核数 |
| `PBS_PPN_MMGBSA` | 8 | MM-GBSA Prime 子作业数 |
| `PBS_WALLTIME_PREP` | `24:00:00` | prep walltime |
| `PBS_WALLTIME_MIN` | `06:00:00` | min walltime |
| `PBS_WALLTIME_MD` | `96:00:00` | MD walltime |
| `PBS_WALLTIME_ANALYSIS` | `12:00:00` | analysis walltime |
| `PBS_WALLTIME_MMGBSA` | `48:00:00` | MM-GBSA walltime |
| `GPU_LICENSE` | `DESMOND_GPGPU:1` | 单个 GPU 作业的 license 串 |
| `MD_MAX_WALLTIME_SEC` | `0` | 0 = 不启用；`auto` = MD walltime − 30 min |

`PBS_WALLTIME_*` 为空字符串时渲染器省略对应 `#PBS -l walltime` 行。

### 3.3 PrepWizard / 建系 / MD / MM-GBSA

| 变量 | 默认 | 说明 |
|---|---|---|
| `PREPWIZARD_PH` | 7.0 | PROPKA pH |
| `PREPWIZARD_DISULFIDES` | yes | 由自由 Cys 生成二硫键 |
| `PREPWIZARD_FILLSIDECHAINS` | yes | Prime 补侧链 |
| `PREPWIZARD_FILLLOOPS` | yes | Prime 补 loop |
| `PREPWIZARD_NOIMPREF` | yes | 跳过受限最小化 |
| `PREPWIZARD_MINIMIZE_ADJ_H` | yes | 最小化可调氢 |
| `PREPWIZARD_LABEL_PKAS` | yes | 标注 PROPKA pKa |
| `FORCEFIELD` | S-OPLS | 力场 |
| `SOLVENT` | SPC | 水模型 |
| `BUFFER_SIZE` | 10.0 | 盒子 buffer（Å） |
| `SALT_CONC` | 0.15 | NaCl 浓度（M） |
| `MD_TIME_NS` | 300 | 生产 MD 时长（ns） |
| `MD_TEMPERATURE` | 300.0 | 温度（K） |
| `MD_TRAJ_INTERVAL_PS` | 1000.0 | 轨迹帧间隔（ps） |
| `MD_CUTOFF` | 9.0 | 非键截断（Å） |
| `MD_SEED` | 空 | 空 = 首次提交生成并冻结 |
| `MMGBSA_LAST_NS` | 100 | 取最后 N ns |
| `MMGBSA_STEP_SIZE` | 2 | 帧步长 |
| `MMGBSA_START_FRAME` / `END_FRAME` | 空 | 显式帧窗口；`END_FRAME` 排他 |
| `RUN_ANALYSIS` / `RUN_MMGBSA` | yes | 阶段开关 |

其他由提交脚本管理的变量：`MIN_SEED`（默认等于 `MD_SEED`）、`RUN_ID`、
`FORCE_STAGES`、`RESTART_MD`、`SIGNATURE`；不要手工写入 `config.sh`。

### 3.4 系统模板与自动生成

`systems/example.conf.example` 是手工配置模板。必填：

- `SYSTEM_NAME`（`[A-Za-z0-9_.-]`，以字母/数字开头）；
- `INPUT_STRUCTURE` 或 `PREPARED_STRUCTURE`；
- `RECEPTOR_ASL`、`LIGAND_ASL`。

可选：`ALIGN_ASL`、`PROJECT_DIR`、科学参数覆盖。`ALIGN_ASL` 默认
`(<RECEPTOR_ASL>) and backbone and not (atom.ele H)`。

输入格式：

| 变量 | 格式 | 行为 |
|---|---|---|
| `INPUT_STRUCTURE` | PDB、MAE、`.maegz` | PrepWizard → 建系 |
| `PREPARED_STRUCTURE` | MAE、`.maegz` | 复制 → 跳过 PrepWizard → 建系 |

同时设置时 **`PREPARED_STRUCTURE` 优先**，`submit_system.sh` 会清空
`INPUT_STRUCTURE`。相对路径按 `.conf` 所在目录解析。

建议：来自 MOE/建模软件、含非标准残基或非标准原子名的结构优先用 MAE。MAE
携带键级和形式电荷；PDB 没有键级，PrepWizard 可能把非标准命名残基误判为链
断裂并添加端基。

批量场景可不手工复制：在存放复合物的目录运行 `init_user.sh`（或
`scripts/generate_systems.sh`）会扫描 `*.pdb/*.mae/*.maegz`，检查所有复合物的
配体是否在同一条链，并为每个复合物生成 `systems/<文件名>.conf`。生成配置只写
`SYSTEM_NAME`、一个结构变量、`RECEPTOR_ASL`、`LIGAND_ASL`，其余走 `config.sh`
默认值，与手工最小配置完全等价；默认写 `INPUT_STRUCTURE`（MAE 也走 PrepWizard），
`--structure-field prepared` 可改为 `PREPARED_STRUCTURE`（仅 MAE/maegz）。
命名模板、清单文件、`--dry-run`、幂等/覆盖策略详见 TUTORIAL 4.7。

---

## 4. 许可证配置

优先使用安装目录内的 license 文件；license server 时在 `config.sh` 中设置：

```bash
SCHRODINGER_LICENSE_FILE="/path/to/license"
# 或
LM_LICENSE_FILE="port@license_server"
```

检查 feature：

```bash
$SCHRODINGER/utilities/licutil -list \
  | grep -E 'DESMOND_MAIN|DESMOND_GPGPU|PRIMEX_MAIN'
```

不要用 `licutil -available` 作为判据：对 uncounted/HOSTID=ANY license 它可能
显示 “No tokens are currently available”，但 feature 实际可用。

feature 需求：

- `DESMOND_MAIN`：建系/最小化/MD；
- `DESMOND_GPGPU`：GPU 版 Desmond；
- `PRIMEX_MAIN`：MM-GBSA。只有 `--no-mmgbsa` 或 `RUN_MMGBSA=no` 时才不要求；
  仅用 `--from analysis` 仍会默认提交 MM-GBSA，因此仍需要 Prime。

`setup_schrodinger_env` 会 `unset` 空的 `SCHRODINGER_HOSTS`/license 变量；
空值被导出会导致 `multisim` 报 `MMJOB_HOSTS_MISSING`。

---

## 5. PBS / Torque 前置条件

### 5.1 队列与资源

```bash
command -v qsub qstat qdel pbsnodes
qstat -q
qstat -Q -f          # 查看队列 walltime/资源上限
pbsnodes -a          # 查看节点、gpus 资源
```

- 队列名写入 `config.sh` 的 `PBS_QUEUE`；
- 目标机 walltime 上限要大于 `PBS_WALLTIME_*`，尤其 `PBS_WALLTIME_MD`；
- Torque 必须配置 `gpus` 资源，否则 `#PBS -l ...:gpus=1` 会报
  `Unknown resource: gpus`；
- 不要因为节点有 4 张卡就写 `gpus=4`；每个 min/MD 只申请 1 张。

### 5.2 GPU 分配

PBS 可通过 `PBS_GPUFILE` 和/或 `CUDA_VISIBLE_DEVICES` 告知作业分配到的 GPU。
推荐管理员在队列 prologue 中导出 `CUDA_VISIBLE_DEVICES`，这样不同用户的作业
不会抢同一张卡。流水线在两者都缺失时会回退到 `nvidia-smi` 最闲卡 + 文件锁，
但该锁只能协调本流水线自己的作业，不能替代调度器。

### 5.3 日志回传

某些 Torque 配置不回传 `#PBS -o` 指定的文件。PBS 模板在作业内部执行
`exec >> "$PBS_OUT" 2>&1`，因此即使调度器不回传，日志仍落在项目
`logs/pbs/` 下。

---

## 6. 目录与内部结构

代码目录：

```
/opt/desmond_md_pipeline/
├── README.md                    管理员手册（本文）
├── TUTORIAL.md                  用户详细教程
├── MULTIUSER.md                 用户快速上手
├── config.sh                    机器/PBS/科学默认参数
├── systems/example.conf.example 体系配置模板
├── examples/                    pilot 配置示例
├── pbs/*.pbs.in                 PBS 模板（提交时渲染）
├── scripts/
│   ├── lib/                     配置、日志、MSJ/CFG、GPU 选择、status 解析/输出
│   ├── stages/                  10_prepwizard ... 60_mmgbsa
│   ├── submit_system.sh         单体系：渲染 + qsub 依赖链
│   ├── submit_batch.sh          多体系批量提交
│   ├── submit_smoke.sh          GPU/license/环境冒烟
│   ├── check_env.sh             登录节点环境检查
│   ├── status.sh                当前阶段 / ETA / 本 run WARN-FATAL
│   ├── collect_results.sh       汇总 RMSD 图与 MM-GBSA 表
│   ├── init_user.sh             初始化工作区 + ~/.bashrc + 自动生成体系
│   ├── generate_systems.sh      批量生成 systems/*.conf（wrapper）
│   ├── generate_systems.py      批量生成的 CLI 与编排
│   ├── system_generation.py     批量发现/配体链检查/命名/写配置
│   └── inspect_structure.py     链/HET/水/离子 + ASL 原子数/链集合
└── tools/
    ├── validate_cms.py          CMS 完整性检查
    ├── compute_ligand_rmsd.py   配体 RMSD
    ├── generate_rmsd_plots.py   RMSD 图
    └── summarize_mmgbsa.py      MM-GBSA 汇总
```

运行时目录（每个用户独立）：

```
$SCH_WORK_ROOT/
├── systems/                     用户的 <name>.conf（可自动生成）
├── projects/<SYSTEM_NAME>/      项目输出（见 TUTORIAL 的输出目录）
├── results/                     collect_results.sh 汇总
└── .gpu_locks/                  GPU 回退锁
```

代码目录下不产生运行数据。

---

## 7. PBS 作业设计

### 7.1 为什么显式 qsub + `-HOST localhost`

旧式做法是通过站点 `schrodinger.hosts` 的 GPU 别名让 Schrödinger 自己提交
作业。问题：

1. 目标机 `/opt/schrodinger2021-2/schrodinger.hosts` 不一定可写；
2. 别名与每节点 GPU 数绑定，换机器要改；
3. 资源、依赖、日志藏在 Schrödinger job control 里，不直观。

本流水线把调度权交给 PBS：

```bash
# 外层：PBS 申请 1 张卡
#PBS -l nodes=1:ppn=1:gpus=1

# 内层：Schrödinger 在 PBS 分配到的节点上本地执行
multisim ... -HOST localhost -maxjob 1 -cpu 1 -WAIT
```

`-HOST localhost` 指当前 PBS 作业所在的计算节点；`-WAIT` 必须加，否则 PBS
脚本会提前退出。不要在登录节点直接跑 GPU 阶段。

### 7.2 模板与渲染

`submit_system.sh` 用 `render_template` 把 `pbs/*.pbs.in` 渲染到
`$SCH_WORK_ROOT/projects/<P>/pbs/<stage>.<run>.pbs`，替换 `@JOBNAME@`、
`@PPN@`、`@WALLTIME_DIRECTIVE@`、`@PBS_OUT@`、`@PROJECT_DIR@` 等占位符。
渲染后检查：

- 纯 ASCII（`qsub` 要求）；
- `bash -n` 语法。

若存在未渲染的 `@...@` 占位符会直接失败。渲染出的脚本是审计/复现依据，
不要手改；修改请改模板或配置。

作业名格式为 `<prefix><slug>`（`mpP/mpM/mpD/mpA/mpG` + 8 字符
`SYSTEM_NAME` slug）。Torque 只可靠显示约 15 字符，所以跟踪作业请用 job id。

### 7.3 依赖链与资源

```
prep ──afterok──► min ──afterok──► md ──afterok──► analysis
                                      └─afterok──► mmgbsa
```

analysis 与 mmgbsa 都依赖 md，彼此不依赖，MD 成功后并行。前置失败时下游
不会运行；Torque 可能把下游显示为 `H` 或 0 时间 `C`。

`submit_system.sh` 会读取 `state/jobs.env`，若发现同一项目仍有 `Q/R/H` 的旧
作业会拒绝新提交，并打印 `qdel` 命令。

### 7.4 渲染出的脚本示例

```bash
#!/bin/bash
#PBS -q batch
#PBS -N mpD_<slug>
#PBS -l nodes=1:ppn=1:gpus=1
#PBS -l walltime=96:00:00
#PBS -j oe
#PBS -r n
#PBS -o <PROJECT_DIR>/logs/pbs/md.<run>.out
# System: <SYSTEM_NAME>
# Stage: md (one GPU)
# This file is rendered by submit_system.sh. Do not edit by hand.
set -euo pipefail
exec >> "<PROJECT_DIR>/logs/pbs/md.<run>.out" 2>&1

PIPELINE_ROOT="/opt/desmond_md_pipeline"
PROJECT_DIR="<PROJECT_DIR>"
RUN_ID="<run>"
export PIPELINE_ROOT PROJECT_DIR RUN_ID

source "${PROJECT_DIR}/project.resolved.conf"
source "${PIPELINE_ROOT}/scripts/lib/common.sh"
source "${PIPELINE_ROOT}/scripts/lib/gpu.sh"

setup_schrodinger_env
select_gpu
bash "/opt/desmond_md_pipeline/scripts/stages/40_md.sh" "${PROJECT_DIR}"
```

要点：

- `#PBS -r n`：失败不自动重跑；
- `source project.resolved.conf`：只读冻结配置；
- `setup_schrodinger_env`：非交互 PBS shell 不读 `~/.bashrc`，显式设置
  `SCHRODINGER`、PATH、license 变量；
- `select_gpu`：见下节；
- 阶段内部把详细日志写到 `logs/<stage>_<jobid>_<time>.log`。

### 7.5 GPU 选卡顺序

`scripts/lib/gpu.sh` 的逻辑：

1. `SCHRODINGER_CUDA_VISIBLE_DEVICES` 与 `CUDA_VISIBLE_DEVICES` 都存在但
   不一致 → 报错；
2. 有 `SCHRODINGER_CUDA_VISIBLE_DEVICES` → 用它；
3. 有 `CUDA_VISIBLE_DEVICES` → 取第一个 ID，并同步到
   `SCHRODINGER_CUDA_VISIBLE_DEVICES`；
4. 有 `PBS_GPUFILE` → 解析分配到的 GPU（兼容 `node-gpu0`、
   `node-gpu/0`、`node:0`、纯数字等格式）；
5. 都没有 → `nvidia-smi` 按显存/利用率选最闲卡，并用 `flock` 在
   `$GPU_LOCK_DIR/<host>_gpu<N>.lock` 加协作锁；抢不到则失败，不超订；
6. 最后用 `nvidia-smi -i <id>` 复核，并导出
   `CUDA_VISIBLE_DEVICES` / `SCHRODINGER_CUDA_VISIBLE_DEVICES`。

阶段结束后检查引擎日志：

```bash
grep 'GPU Desmond started' desmond_md_job_<P>.log
grep 'uuid0: GPU-'         desmond_md_job_<P>.log
```

没有 GPU 行会失败，不会静默用 CPU 跑长 MD。

### 7.6 与 `schrodinger.hosts` 集成方式对比

站点 hosts 别名示例：

```text
name:        GPU_Nodes_4str
host:        node01
queue:       Torque
qargs:       -l nodes=1:ppn=1:gpus=1
gpgpu:       0, 1, 2, 3
can_gpgpu:   YES
schrodinger: /path/to/schrodinger
```

- `gpgpu: 0,1,2,3` 只是声明节点有 4 张卡；`qargs` 的 `gpus=1` 才是每作业
  申请 1 张；
- `host` 是 Torque 提交服务器，换集群要改；
- 需要写 `/opt/.../schrodinger.hosts`，普通用户可能没权限；
- 资源/依赖/日志由 Schrödinger job control 管理，不如显式 qsub 透明。

本流水线不需要修改 hosts；如确实要用 hosts 集成（例如 Maestro GUI 提交），
按上面格式单独维护，不要依赖本流水线。

---

## 8. 各阶段内部说明

### 8.1 `10_prepwizard.sh`

两种模式：

1. `INPUT_STRUCTURE`（PDB/MAE/maegz）：运行

```bash
$SCHRODINGER/utilities/prepwizard <input> prepwizard-out.maegz \
  -propka_pH 7.0 -disulfides -f S-OPLS \
  -minimize_adj_h -label_pkas \
  -fillsidechains -fillloops \
  -noimpref \
  -HOST localhost -WAIT
```

2. `PREPARED_STRUCTURE`（MAE/maegz）：复制为
   `prepwizard/prepwizard-out.maegz`，跳过 PrepWizard；仍会校验 CMS/ASL。

参数由 `PREPWIZARD_*` 控制。输出立即用 `tools/validate_cms.py` 解析所有 CT，
并用 `inspect_structure.py` 检查 ligand/align ASL 非空。`inspect_structure.py
--json-out` 的 `asl.<label>` 现在还包含 `chains`（选中原子所在的链集合），
批量生成器据此检查同一批复合物的配体链是否一致。

### 8.2 `20_setup.sh`

生成并执行 MSJ：

```text
task { task = "desmond:auto" }
build_geometry {
  box: orthorhombic, size = [10 10 10], size_type = buffer
  solvent = SPC
  salt = 0.15 M NaCl
  add_counterion = Na, neutralize_system
  override_forcefield = S-OPLS
  rezero_system = false
}
assign_forcefield { forcefield = S-OPLS }
```

命令：

```bash
multisim -JOBNAME desmond_setup_<P> -m <msj> \
  prepwizard-out.maegz -o desmond_setup_<P>-out.cms \
  -HOST localhost -WAIT
```

输出 CMS 可能含多个 CT；`validate_cms.py` 遍历所有 CT，
`inspect_structure.py` 用第一个 CT 做 ASL 检查。

### 8.3 `30_min.sh`

- 100 ps Brownian NVT 10 K，solute heavy-atom restraint 50 kcal/mol；
- timestep `[0.001 0.001 0.003]`，cutoff 9 Å，4.8 ps 轨迹帧；
- 随后 cfg 段（另一段 100 ps 低温柔化），合计约 200 ps。

命令核心：

```bash
multisim -JOBNAME desmond_min_job_<P> -m <msj> -c <cfg> \
  -HOST localhost -maxjob 1 -cpu 1 \
  desmond_setup_<P>-out.cms -mode umbrella \
  -o desmond_min_job_<P>-out.cms -lic "$GPU_LICENSE" -WAIT
```

验收：CMS 可解析、配体/对齐 ASL 非空、引擎日志有 `GPU Desmond started`。

### 8.4 `40_md.sh`

5 段标准 NPT 弛豫 + 生产：

1. 100 ps Brownian NVT 10 K，heavy-atom restraint 50；
2. 12 ps Langevin NVT 10 K，restraint 50；
3. 12 ps Langevin NPT 10 K，restraint 保持；
4. 12 ps Langevin NPT 目标温度，restraint 保持；
5. 24 ps Langevin NPT，无 restraint；
6. 生产 NPT：300 K，默认 300 ns，2 fs，MTK barostat tau 2.0，
   1.01325 bar，cutoff 9 Å。

输出：

```text
desmond_md_job_<P>-out.cms
desmond_md_job_<P>_trj/          # DTR 轨迹
desmond_md_job_<P>.log           # 引擎日志
desmond_md_job_<P>.cpt           # checkpoint
desmond_md_job_<P>_N-out.tgz     # 各阶段数据
```

MD MSJ 不带 `pl_analysis`：分析放在 CPU 的 `50_analysis.sh`，避免分析失败
拖垮整个 GPU 阶段，也节省 GPU 时间。

结束检查：

- 最终 `Chemical time` ≥ 99% 请求时长；否则 exit 42，下游不运行；
- `GPU Desmond started`；
- 输出 CMS 可解析、配体/ASL 非空。

### 8.5 `50_analysis.sh`

```bash
# 1) 对齐：只用受体主链重原子
trj_align.py <md-out.cms> <md_trj> aligned_<P> -asl "$ALIGN_ASL"

# 2) EAF
event_analysis.py analyze aligned_<P>-out.cms \
  -prot "$RECEPTOR_ASL" -lig "$LIGAND_ASL" -out "<P>"

# 3) 从 EAF 计算 RMSD（直接跑，不进 job control）
analyze_simulation.py aligned_<P>-out.cms aligned_<P>_trj \
  <P>-out.eaf <P>-in.eaf -NOJOBID

# 4) 配体 RMSD（Desmond LigandRMSD，含对称性处理）
$SCHRODINGER/run python3 tools/compute_ligand_rmsd.py \
  --cms aligned_<P>-out.cms --ligand-asl "$LIGAND_ASL" \
  --fit-asl "$ALIGN_ASL" --output-dir . --prefix <P> \
  --traj-interval "$MD_TRAJ_INTERVAL_PS"

# 5) XLSX/PNG
$SCHRODINGER/run python3 tools/generate_rmsd_plots.py \
  --traj-interval "$MD_TRAJ_INTERVAL_PS" --output-dir . <P>-out.eaf
```

历史修正（不要回退）：

- `event_analysis.py -out` 传 basename，避免 `xxx.eaf-in.eaf`；
- `--traj-interval` 一律传 ps；
- 只对 `<P>-out.eaf` 出图；
- 对齐只用受体主链，不用 protein+ligand 一起对齐；
- 所有 Python 都用 `$SCHRODINGER/run python3`，不依赖 conda。

Schrödinger 自带环境的 pandas/xlsxwriter 版本提示可忽略，XLSX 仍能写出。
输出在 `analysis/align/`、`analysis/rmsd/`，并复制到 `results/`。

### 8.6 `60_mmgbsa.sh`

```bash
$SCHRODINGER/run thermal_mmgbsa.py <md-out.cms> \
  -HOST localhost:$PBS_PPN_MMGBSA -NJOBS $PBS_PPN_MMGBSA \
  -lig_asl "$LIGAND_ASL" -frozen -step_size 2 \
  -j mmgbsa_<P> -start_frame 200 -end_frame 301
```

- 轨迹含 t=0 帧：总帧数 = `floor(MD_TIME_PS / MD_TRAJ_INTERVAL_PS) + 1`；
- 默认窗口是 `min(MMGBSA_LAST_NS, MD_TIME_NS)` 的最后一段；300 ns、1 ns/帧、
  last 100 ns → start=200，end=301（排他，含 t=300 ns 帧），step=2 → 51 帧；
- 显式 `MMGBSA_START_FRAME`/`END_FRAME` 优先；`END_FRAME` 仍是排他上界；
- `-HOST localhost:$PPN -NJOBS $PPN` 让 Prime 在 PBS 作业所在节点本地并行；
  不要指向登录节点或其他主机；
- `tools/summarize_mmgbsa.py` 按 `r_psp_MMGBSA_dG_Bind` 列输出
  `summary.json`/`summary.md`（n、mean、std、sem、min、max）。

输出：`analysis/mmgbsa/mmgbsa_<P>-prime-out.csv`、`summary.md`、
`results/mmgbsa_summary.md`。

---

## 9. 多用户模型与权限

- 代码只读共享，所有用户运行同一份脚本；
- 每个用户独立 `SCH_WORK_ROOT`；默认是运行 `init_user.sh` 的目录（记录在
  `.desmond_work_root`），不可写时回退 `$HOME/desmond_md_work`；`~/.bashrc`
  托管块导出该路径并配置 `desmond-*` 别名；
- `project.resolved.conf` 冻结提交时的参数，升级代码不会改变已提交项目的
  科学参数；
- 每个用户用自己的账号提交 PBS 作业，作业和输出归该用户；
- 不要共享 `SCH_WORK_ROOT`，否则同名体系/输出会互相覆盖；
- 不要把 license、密钥、未公开结构放进共享代码目录。

GPU 回退锁：

- 默认 `GPU_LOCK_DIR=$SCH_WORK_ROOT/.gpu_locks`，每个用户独立；
- 若站点既不导出 `CUDA_VISIBLE_DEVICES` 也不提供 `PBS_GPUFILE`，可设置一个
  组可写的共享目录让本流水线跨用户协调，但这不能替代调度器；
- 最稳妥的方案是管理员在队列 prologue 导出 `CUDA_VISIBLE_DEVICES`。

---

## 10. 升级与维护

### 10.1 更新共享代码

```bash
sudo rsync -a --delete \
  --exclude projects --exclude results --exclude .gpu_locks \
  <new-source>/ /opt/desmond_md_pipeline/
```

推荐版本目录 + 软链接：

```bash
sudo cp -a /opt/desmond_md_pipeline /opt/desmond_md_pipeline-<date>
sudo ln -sfn /opt/desmond_md_pipeline-<date> /opt/desmond_md_pipeline
```

回滚时把软链接指回旧版本。用户不需要复制代码，下一次运行自动使用新版本。

### 10.2 签名与续跑

`SIGNATURE` 包含输入 sha256 和科学参数（PrepWizard 选项、力场/溶剂/盐、
MD 时长/温度/轨迹间隔/cutoff、ASL、MM-GBSA 窗口等）。升级后若签名算法或
默认值变化，续跑旧项目会被拒绝；按提示使用显式 `--from <stage>` 或
`--force` 确认。已冻结的 `project.resolved.conf` 保留旧参数。

### 10.3 文档维护

- 用户文档（`TUTORIAL.md`、`MULTIUSER.md`）不写部署、内部实现、验证记录和
  本机路径；
- 管理员内容（本文）承接部署、配置参考、PBS 设计、阶段内部、升级、排错；
- 文档中的命令/flag 必须与脚本 `--help` 和 `config.sh` 一致；
- 三份文档的最后更新时间同步。

---

## 11. 已知限制与管理员排错

### 11.1 walltime、checkpoint 与重启

MD scratch 位置由 `SCHRODINGER_TMPDIR`/站点配置决定（本集群为 `$HOME/tmp`，
部分集群为 `/var/tmp/$USER`）；目录名包含 jobname，按作业隔离。如果 scratch
在计算节点本地而不是共享文件系统：

- 正常完成：`-out.cms`、`_trj/`、`.cpt`、`*-out.tgz` 回传到项目目录；
- `qdel` 或 walltime 硬杀：运行中的临时 checkpoint 可能留在节点本地，无法
  回传。

因此**首选把 `PBS_WALLTIME_MD` 设得比预计 MD 时长长**。`MD_MAX_WALLTIME_SEC`
默认 0（不启用 `-max-walltime`）。

**2021-2 实测限制**：生产阶段被中断后，`multisim -RESTART` 会报
`desmond_md_job_<P>-in.cfg is not accessible`；尝试从 `.cfg` 重建、使用
`-d _N-out.tgz`、`-c` 或不加 `-d` 均未恢复。`--restart-md` 仅保留为实验性
入口，不能作为生产恢复方案。目标机 walltime 上限短时，应拆分 MD 或提高
walltime；`--force md` 会归档旧结果并从头重跑。

### 11.2 常见 PBS 错误

| 现象 | 可能原因 | 检查 | 处理 |
|---|---|---|---|
| `qsub: file must be an ascii script` | PBS 脚本有非 ASCII | `file <pbs>` | 模板渲染后自动检查；不要把中文写进 `.pbs` |
| `Unauthorized Request` / `trqauthd` 失败 | 在计算节点提交 | `hostname`、`echo $PBS_JOBID` | 回登录节点提交 |
| 作业一直 `Q` | 资源不满足/GPU 被占/请求过大 | `qstat -n`、`pbsnodes -a` | 等待；确认 `gpus=1` |
| 下游 `H` 或 0 时间 `C` | 前置作业失败，`afterok` 未满足 | `qstat -f <id>` 的 `comment`、前置日志 | 修复前置；`qdel` 残留；`--from` 重提 |
| 找不到 `.o` 文件 | 调度器不回传 `#PBS -o` | `qstat -f <id>` 的 `Output_Path` | 本流水线已在作业内部重定向 |
| 作业名被截断/重名 | Torque 约 15 字符 | `qstat -u $USER` | 用 job id 跟踪 |
| Desmond 没用 GPU | 没设 CVD/PBS_GPUFILE 或驱动异常 | 引擎日志 `GPU Desmond started` | 跑 smoke；检查 `gpus=1` 和 CVD |
| 两个作业抢同一张卡 | 调度器未导出 CVD/PBS_GPUFILE | 两个作业的 `GPU selected` 日志 | 让管理员在队列层导出 CVD |
| `Unknown resource: gpus` | Torque 未配置 GPU 资源 | `pbsnodes -a \| grep gpus` | 联系管理员配置；不要偷偷去掉 `gpus=1` |
| `MMJOB_HOSTS_MISSING` | 空的 `SCHRODINGER_HOSTS` 被导出 | `env \| grep SCHRODINGER_HOSTS` | `setup_schrodinger_env` 会 unset 空值；检查外部脚本 |
| license 报错 | 缺 feature/服务器不可达 | `licutil -list` | 配置 license server；检查 feature |
| 日志时间对不上 | 节点时钟不同步 | `date` | 用 job id/qstat，不用 mtime 排序 |
| 作业结束但项目里没有轨迹 | scratch 在节点本地，未回传/被清理 | 作业日志、节点 `/var/tmp` | 设足 walltime；不要硬杀；重启不可靠 |

### 11.3 其他注意

- `licutil -available` 对 uncounted license 无意义，用 `-list`；
- 某些 Torque 不回传 `#PBS -o`，模板已处理；
- 节点时钟不同步，不要用不同节点的日志时间戳判断先后；
- 队列内存不限额时，注意同节点多作业内存叠加；`PBS_PPN_MMGBSA` 太大可能
  让多个 Prime 子作业占满内存，先降到 4 或 2；
- 部分 `qstat` 扩展字段（例如按 GPU 过滤、已完成作业历史）依赖 Torque
  版本/站点配置；脚本不依赖这些字段，跟踪作业以 job id 和 `job_state` 为准。

---

## 12. 部署验收清单

- [ ] `/opt/schrodinger2021-2/version.txt` 为 2021-2（Build 117 最好）
- [ ] `licutil -list` 有 `DESMOND_MAIN`、`DESMOND_GPGPU`、`PRIMEX_MAIN`
- [ ] `qsub/qstat/qdel/pbsnodes` 在 PATH；队列名与 `config.sh` 一致
- [ ] 部署/升级前确认队列为空（`qstat -u "$USER"` 无 Q/R/H），或接受在途
      作业使用新版脚本
- [ ] `qstat -Q -f` 确认 walltime 限制，调整 `PBS_WALLTIME_*`
- [ ] `pbsnodes -a` 的 `gpus` 数与节点实际 `nvidia-smi -L` 一致
- [ ] `check_env.sh` 无 FAIL
- [ ] `submit_smoke.sh` 成功，日志有 `SMOKE_OK`
- [ ] smoke 日志记录 `PBS_GPUFILE` 格式、是否导出 `CUDA_VISIBLE_DEVICES`
- [ ] 计算节点可读写项目目录、`$HOME/.schrodinger`、scratch
- [ ] `$SCHRODINGER/run python3` 能导入 pandas/matplotlib/openpyxl/Desmond API
- [ ] 用 0.1 ns pilot 跑通全链（prep → min → md → analysis/mmgbsa）
- [ ] 确认 MD 预计时长 < `PBS_WALLTIME_MD`（留足余量）
- [ ] 确认 `MD_TIME_NS`、`MMGBSA_LAST_NS`、`PBS_WALLTIME_MD` 后再提交生产

---

## 13. 验证记录

以下记录只保留结论，不包含具体用户路径、体系代号、job id 或运行速率。

- 环境检查：登录节点 PASS 数正常，唯一 WARN 是登录节点无 GPU；无 FAIL。
- GPU smoke：在 GPU 节点成功，`PBS_GPUFILE`/`CUDA_VISIBLE_DEVICES` 可用，
  license、Python 依赖、共享目录写权限通过，输出 `SMOKE_OK`。
- 0.1 ns 全链 pilot：prep → min → md → analysis/mmgbsa 全部完成；MD 达到
  请求时长的 99% 以上；analysis 输出 RMSD CSV/XLSX/PNG；MM-GBSA 输出
  summary。
- 原始复合物走 PrepWizard 的路径已验证；prep PBS 作业可在 CPU 节点完成
  PrepWizard + 建系。
- 失败依赖行为已验证：前置 min 失败时下游不运行。
- MAE 输入验证（2026-11-16）：含蛋白链、小分子配体及 Ca/Cl/Zn 离子的 Maestro
  `.mae` 复合物通过 PrepWizard + system build；配体原子组成与连通性保持不变，
  溶剂/离子/盒子与同源 PDB 输入一致。差异仅为蛋白少数可电离/非标准命名残基的
  质子化/端基处理；MAE 的显式键级还避免了 PDB 路径对非标准残基的链断裂误判。
  该结论已脱敏，不包含用户路径、体系代号或具体原子数。
- 已知限制：2021-2 的 `multisim -RESTART` 对中断的生产阶段不可靠，见
  “已知限制与管理员排错”。

---

## 附录 A：qsub 最小调试模板

```bash
#!/bin/bash
#PBS -N test_gpu
#PBS -q batch
#PBS -l nodes=1:ppn=1:gpus=1
#PBS -l walltime=00:10:00
#PBS -j oe
#PBS -r n
#PBS -o /absolute/path/test_gpu.out
set -euo pipefail
export SCHRODINGER=/opt/schrodinger2021-2
nvidia-smi -L
echo "PBS_GPUFILE=${PBS_GPUFILE:-unset}"
[ -n "${PBS_GPUFILE:-}" ] && cat "$PBS_GPUFILE"
```

```bash
qsub test_gpu.pbs
qstat -f <jobid>
```

---

*最后更新：2026-11-16*
