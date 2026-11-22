# 蛋白–配体 Desmond MD 流水线用户教程

本教程面向使用共享安装 `/opt/desmond_md_pipeline` 的普通集群用户。流水线覆盖：

```
蛋白–配体复合物
   │
   ▼
[prep]      CPU   PrepWizard（可选）+ Desmond 建系
   │
   ▼
[min]       1 GPU 最小化 / 低温柔化
   │
   ▼
[md]        1 GPU 5 段 NPT 弛豫 + 生产 MD
   │
   ├──────────────► [analysis]  CPU  轨迹对齐 + RMSD + 出图
   └──────────────► [mmgbsa]    CPU  MM-GBSA
```

每个阶段是一个独立的 PBS 作业，用 `afterok` 依赖串联。`analysis` 和 `mmgbsa`
都依赖 MD，MD 成功后并行运行。

**适用范围**：常规可溶性蛋白–配体复合物（小分子、环肽、多肽、辅因子等），
输入为 PDB、MAE 或 `.maegz`。不适用于膜蛋白/膜体系、已溶剂化的 CMS，或需要
单作业多 GPU 的 MD。

快速上手请看 **[MULTIUSER.md](MULTIUSER.md)**；部署、升级、PBS 内部设计和
管理员排错见 **[README.md](README.md)**。

---

## 1. 流水线概览

| 阶段 | PBS 资源 | 默认 walltime | 主要输出 |
|---|---|---|---|
| prep | CPU `ppn=4` | 24 h | `prepwizard-out.maegz`、setup CMS |
| min | 1 GPU | 6 h | 最小化 CMS |
| md | 1 GPU | 96 h | MD CMS、轨迹、引擎日志、checkpoint |
| analysis | CPU `ppn=1` | 12 h | 对齐轨迹、EAF、RMSD CSV/XLSX/PNG |
| mmgbsa | CPU `ppn=8` | 48 h | MM-GBSA CSV、`summary.md/json` |

时间预期（RTX 3090 级别，供规划参考）：prep 数分钟；min 数分钟到十几分钟；
MD 约 18–24 h / 300 ns；analysis 数分钟；MM-GBSA 取决于帧数，通常十几分钟到
数小时。实际以集群和体系为准。

每个 min/MD 作业只申请 **1 张 GPU**；每节点有 2/4/8 张卡只影响同时能跑几个作业，
不需要改脚本。

---

## 2. 首次使用

```bash
# 在你想放 projects/ 的目录运行（默认工作区就是当前目录）
cd /home/user1/Documents/PSMA_PDC/PDC/test
/opt/desmond_md_pipeline/scripts/init_user.sh
```

init 会创建 `projects/ systems/ results/ .gpu_locks/`，写入
`.desmond_work_root` 标记，并在 `~/.bashrc` 的托管块中写入：

```bash
if [[ -z "${SCH_WORK_ROOT:-}" ]]; then
  export SCH_WORK_ROOT='/home/user1/Documents/PSMA_PDC/PDC/test'
fi
alias desmond-init='/opt/desmond_md_pipeline/scripts/init_user.sh'
# ... desmond-check/smoke/submit/batch/status/results/systems
```

init 默认直接更新 `~/.bashrc` 托管块，不生成 `.desmond.bak.*` 备份文件；
不需要改 shell 配置时加 `--no-bashrc`，init 会把 export 和 alias 打印出来
供手工粘贴。

如果运行 init 的目录里有 `*.pdb` / `*.mae` / `*.maegz` 复合物，init 还会
自动检查配体链并生成 `systems/*.conf`（见 4.7）；不需要时加 `--no-systems`。

当前 shell 执行 `source ~/.bashrc` 后即可使用 `desmond-status` 等快捷命令；
如果当前 shell 已经有旧的 `SCH_WORK_ROOT`，用
`unset SCH_WORK_ROOT && source ~/.bashrc`。别名只在交互 shell 有效；
`ssh host desmond-status` 或脚本里请用绝对路径或显式 export。

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
- 重新 init 到不同目录时，`~/.bashrc` 托管块会被替换；旧项目不移动，仍在旧
  工作区。改变已有托管块指向的 root 需要 `--force`；`--work-root` 只指定
  路径，不绕过这项确认。
- `SCH_WORK_ROOT` 必须在登录节点和计算节点都可访问；冻结配置里保存的是绝对路径。
- 不要以 `root` 身份运行普通用户作业。

从旧版本升级：在旧工作区里重新运行一次 `init_user.sh` 补上
`.desmond_work_root`（项目和输出不动）；也可以继续显式
`export SCH_WORK_ROOT=<旧路径>`。`WORK_ROOT` 已更名为 `SCH_WORK_ROOT`；
`PIPELINE_WORK_ROOT` 仍作为兼容别名；旧项目 `project.resolved.conf` 里的
`WORK_ROOT` 会在阶段运行时自动迁移。旧 `.done` 没有 `RUN_ID` 也能被
`status.sh` 正确识别（回退比较 `JOBID`），不需要手工修改。

工作区结构：

```
$SCH_WORK_ROOT/
├── .desmond_work_root  # 工作区标记；config.sh 从这里向上查找
├── systems/     # 你自己的 <name>.conf
├── projects/    # 每个体系一个项目目录
├── results/     # collect_results.sh 的跨体系汇总
└── .gpu_locks/  # GPU 回退锁（通常不需要关心）
```

---

## 3. 准备输入

### 3.1 支持的输入格式

| 变量 | 接受的格式 | 行为 |
|---|---|---|
| `INPUT_STRUCTURE` | PDB、MAE、`.maegz` | 先运行 PrepWizard，再由 Desmond 建系 |
| `PREPARED_STRUCTURE` | MAE、`.maegz` | 跳过 PrepWizard，直接建系 |

- 两者只设置一个。若都设置，**`PREPARED_STRUCTURE` 优先**，冻结配置会清空
  `INPUT_STRUCTURE`。
- 相对路径按 `.conf` 所在目录解析；建议写绝对路径。
- `.mae`/`.maegz` 是 Maestro 格式，可直接作为 `INPUT_STRUCTURE`，由
  PrepWizard 重新质子化/补侧链/补 loop。
- 多 CT 的 MAE 只使用第一个 CT；请在提交前确认文件里只有一个复合物。

> 提示：如果结构来自 MOE/建模软件，且含非标准残基或非标准原子名，优先直接
> 使用 `.mae`。PDB 不携带键级，PrepWizard 可能把这类残基误判为链断裂并添加
> 端基；MAE 会保留原始键级和形式电荷。

### 3.2 结构要求

- 一个蛋白–配体复合物，三维坐标完整；
- 配体在独立链或明确残基上（如 `chain B`、`res.ptype LIG`）；
- 不要预先溶剂化或加中和离子；流水线会按 `BUFFER_SIZE` / `SALT_CONC` 建系。
  结构自身必要的金属/结构离子可以保留（PrepWizard 会处理）；
- 建议去除无关的远端水分子和多余副本；
- 缺失残基/链断裂由 PrepWizard 的 `-fillsidechains` / `-fillloops` 处理；
  大段缺失或无法闭合的 loop 需要你事先补全或在配置中关闭相应选项。

### 3.3 检查链与 ASL

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

输出会列出每条链的原子/残基数、HET 基团、水、离子，以及每个 ASL 选中的
原子数，并给出 `chain X` 建议。任何 ASL 选中 0 个原子时 `--check` 会非零退出。

---

## 4. 配置体系

### 4.1 复制模板

```bash
cp /opt/desmond_md_pipeline/systems/example.conf.example \
   "$SCH_WORK_ROOT/systems/my_sys.conf"
vi "$SCH_WORK_ROOT/systems/my_sys.conf"
```

### 4.2 最小配置

```bash
SYSTEM_NAME="my_sys"
INPUT_STRUCTURE="/absolute/path/to/complex.pdb"
RECEPTOR_ASL="chain A"
LIGAND_ASL="chain B"
```

`SYSTEM_NAME` 只允许 `[A-Za-z0-9_.-]`，并用于输出路径和 PBS 作业名。
可选 `PROJECT_DIR` 指定输出目录，默认
`$SCH_WORK_ROOT/projects/<SYSTEM_NAME>`；路径会嵌入 PBS 脚本，必须纯 ASCII、
无空格/引号。

### 4.3 ASL 示例

| 场景 | 写法 |
|---|---|
| 配体在单独链 | `LIGAND_ASL="chain B"` |
| 配体是某个残基名 | `LIGAND_ASL="res.ptype LIG"` |
| 多残基/环肽/多肽 | `LIGAND_ASL="chain B"`（配体自成一链最稳） |
| 受体为标准聚合物 | `RECEPTOR_ASL="protein"` |
| 受体是某条链（推荐，含非标准残基） | `RECEPTOR_ASL="chain A"` |
| 排除水/离子 | `LIGAND_ASL="chain B and not (water or ions)"` |

默认对齐选择是：

```
(<RECEPTOR_ASL>) and backbone and not (atom.ele H)
```

即只用受体主链重原子对齐；不要把配体放进对齐选择，否则配体运动会被人为抵消。

### 4.4 常用科学参数

可在 `systems/<name>.conf` 中覆盖（只列常用项）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `MD_TIME_NS` | 300 | 生产 MD 时长（ns） |
| `MD_TEMPERATURE` | 300.0 | 温度（K） |
| `MD_TRAJ_INTERVAL_PS` | 1000.0 | 轨迹帧间隔（ps） |
| `MD_CUTOFF` | 9.0 | 非键截断（Å） |
| `MD_SEED` | 空 | 空 = 首次提交生成并冻结 |
| `MMGBSA_LAST_NS` | 100 | 取最后 N ns；MD 更短则取全部 |
| `MMGBSA_STEP_SIZE` | 2 | 帧步长 |
| `MMGBSA_START_FRAME` / `END_FRAME` | 空 | 显式帧窗口；`END_FRAME` 为排他上界 |
| `PREPWIZARD_PH` | 7.0 | PrepWizard/PROPKA pH |
| `PREPWIZARD_DISULFIDES` | yes | 由自由 Cys 生成二硫键 |
| `PREPWIZARD_FILLSIDECHAINS` / `FILLLOOPS` | yes | 补侧链/loop |
| `PREPWIZARD_MINIMIZE_ADJ_H` / `LABEL_PKAS` | yes | 最小化可调氢/标注 pKa |
| `PREPWIZARD_NOIMPREF` | yes | 跳过受限最小化 |
| `FORCEFIELD` / `SOLVENT` | S-OPLS / SPC | 力场/水模型 |
| `BUFFER_SIZE` / `SALT_CONC` | 10.0 Å / 0.15 M | 盒子缓冲/盐浓度 |
| `RUN_ANALYSIS` / `RUN_MMGBSA` | yes | 等价于 `--no-analysis` / `--no-mmgbsa` |

机器/PBS/license 参数（`PBS_QUEUE`、`PBS_WALLTIME_*`、`GPU_LICENSE` 等）由
管理员在 `config.sh` 中设置；普通用户通常不需要改，确有需要时可在自己的
`.conf` 中覆盖。

### 4.5 单位

| 用户输入 | 内部/工具 | 说明 |
|---|---|---|
| `MD_TIME_NS=300` | `MD_TIME_PS=300000.0` | Desmond cfg 用 ps |
| `MD_TRAJ_INTERVAL_PS=1000` | 1 ns/帧 | RMSD 工具使用 ps |
| `MMGBSA_*_FRAME` | 帧 | `END_FRAME` 为排他上界 |

### 4.6 种子与签名

- 首次提交若 `MD_SEED` 为空，会生成随机种子并写入
  `project.resolved.conf` 和 `state/run.env`；后续提交复用，不重新随机。
- 输入文件 sha256 + 科学参数生成 `SIGNATURE`。若已有完成阶段且签名变化，
  提交会被拒绝，必须显式 `--force` 或 `--from`。
- `--force` 不删除旧结果，而是把旧目录重命名为 `<dir>.bak.<timestamp>`。

### 4.7 批量生成体系配置

如果同一靶标有多个配体复合物，不必手工复制模板。`init_user.sh` 默认会
扫描**运行 init 的目录**（不是 `--work-root`）下的 `*.pdb`、`*.mae`、
`*.maegz`，检查所有复合物的配体是否在同一条链上；一致时为每个复合物生成
`systems/<复合物名>.conf`，不一致则报错并提示统一配体链，不会写入任何配置。

```bash
cd /home/user1/Documents/PSMA_PDC/PDC
/opt/desmond_md_pipeline/scripts/init_user.sh          # 自动扫描并生成
```

也可以单独运行生成器（推荐先 `--dry-run` 看计划）：

```bash
cd /home/user1/Documents/PSMA_PDC/PDC

# 只打印将生成的体系名/路径/ASL，不落盘
desmond-systems --dry-run

# 指定配体链（例如自动识别有歧义时）
desmond-systems --ligand-chain B

# 扫描其他目录
desmond-systems --input-dir /path/to/complexes

# 显式清单（每行一个路径，# 注释；相对路径按清单所在目录解析）
desmond-systems --manifest structures.txt

# 自定义体系名：{target}_{ligand}_{index}
desmond-systems --target PSMA \
  --name-template '{target}_{ligand}_{index:02d}'
```

常用参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--input-dir DIR` | 当前目录 | 扫描目录（不递归） |
| `--recursive` | 关 | 递归扫描；跳过隐藏目录、`projects/`、`results/`、`systems/`、`.gpu_locks/` 和嵌套 work root |
| `--manifest FILE` | 无 | 显式文件清单，优先于 `--input-dir` |
| `--ligand-chain ID` | 自动识别 | 强制配体链；支持肽类配体 |
| `--ligand-resname NAME[,..]` | 无 | 按残基名选择配体；生成 `chain X and res.ptype NAME` 形式的 ASL |
| `--ligand-asl ASL` | 无 | 显式配体 ASL；支持配体与蛋白共享链（受体会减去该 ASL） |
| `--structure-field {input,prepared}` | `input` | 写 `INPUT_STRUCTURE`（PrepWizard）或 `PREPARED_STRUCTURE`（跳过 PrepWizard；仅 MAE/maegz） |
| `--name-template TPL` | `{stem}` | 支持 `{stem}` `{target}` `{ligand}` `{index}` |
| `--target NAME` | 无 | `{target}` 的值，也用于从文件名剥离配体名 |
| `--ligand-name-source LIST` | `filename,resname,index` | `{ligand}` 的取值优先级 |
| `--name-conflict {error,suffix}` | `error` | 规范化后重名时：报错或追加 `_2`、`_3` |
| `--on-existing {skip,overwrite,error}` | `skip` | 已存在同名配置时的策略 |
| `--overwrite` / `--skip` | `skip` | 上面策略的快捷方式 |
| `--dry-run` | 关 | 只打印计划，不写 `systems/` |

命名与路径规则：

- 默认体系名就是复合物文件名去掉扩展名；非法字符（空格等）替换为 `_`，
  首字符不是字母/数字时加前缀 `s`。仅大小写不同的体系名在 Linux 上允许
  （会警告）；在大小写不敏感的文件系统（SMB/CIFS、macOS）上请用不同模板
  或 `--name-conflict error` 避免同名。
- `{index}` 是发现顺序（manifest 行序或目录内文件名排序）的 1 基编号，
  即使某个文件后续解析失败，它仍占用一个编号。
- `{ligand}` 默认先尝试文件名（`--ligand-regex` 的 `ligand` 命名组/第 1 捕获组；
  否则剥离 `--target` 前缀），再尝试残基名（`UNK/UNL/LIG/MOL` 等泛化名跳过），
  最后回退到 `{index}`。
- 配置里的结构路径一律是**绝对路径**（`realpath`）；`.conf` 本身仍在
  `$SCH_WORK_ROOT/systems/`。
- 生成配置只写 4 个必填字段，其余参数留空走 `config.sh` 默认值，与手工最小配置
  完全等价；下游 `submit_system.sh` / `submit_batch.sh` 无需改动。

生成结果示例：

```bash
# systems/pdc1.conf
SYSTEM_NAME="pdc1"
INPUT_STRUCTURE="/home/user1/Documents/PSMA_PDC/PDC/pdc1.mae"
RECEPTOR_ASL="chain A"
LIGAND_ASL="chain B"
```

```text
systems/
├── example.conf          # init 复制的模板；目录批量提交默认跳过
├── pdc1.conf
├── PDC1_1.conf
├── pdc2.conf
└── pdc2_7.conf
```

配体识别与报错：

- 默认把“有非聚合物 HET 基团”的链当作候选配体链（水、离子、标准聚合物残基
  已被 `inspect_structure.py` 排除）；必须恰好一条，否则报错并提示用
  `--ligand-chain` / `--ligand-resname`。
- 同一链上有多个 HET 基团（如 `UNK` + `UNL`）时，默认报错；用
  `--ligand-resname UNK` 生成残基限定 ASL，或用 `--ligand-asl` 精确选择。
  若同名残基出现在多条链上，可同时用 `--ligand-resname UNK --ligand-chain B`
  限定链。
- 链 ID 为空或含空格等特殊字符时，`--ligand-chain`/自动模式无法构造合法的
  `chain X` ASL；请用 `--ligand-asl` 指定配体，受体回退为 `protein`。
- 所有成功解析的复合物必须得到相同的配体链；不一致时打印每个文件的链 ID
  并退出 1，不生成任何配置。先统一输入结构的链 ID，或用 `--ligand-chain`
  强制选择。
- `--ligand-resname` 生成 `LIGAND_ASL="chain B and res.ptype UNK"`，并用
  Schrödinger ASL 检查确认选中的原子数与目标残基一致；不一致会要求改用
  `--ligand-asl`。
- `--ligand-asl` 用于共享链/特殊选择；若配体与蛋白在同一条链，生成的
  `RECEPTOR_ASL` 形如 `(chain A) and not (<配体 ASL>)`，不会丢掉该链的蛋白。

幂等与失败处理：

- 重复运行默认 `skip`：内容相同打印 `[SKIP]`；内容不同打印 `[WARN] ... kept`
  并保留你手工改过的文件，需 `--overwrite` 才会重写。
- `--on-existing error` 把内容不同的已有配置记为失败；`--overwrite` 重写并
  警告手工修改会丢失。
- 单个结构解析失败只记录并跳过，其余体系继续生成；最后打印
  `created/overwritten/skipped/failed` 汇总，有失败时退出码为 1。
- 每个结构会调用两次 `inspect_structure.py`（报告 + ASL 检查）；约 10 个配体
  通常需要 20–40 秒。`--dry-run` 也会做完整检查。

注意：`init_user.sh` 只复制 `systems/example.conf` 作为手工模板，它含占位路径。
`desmond-batch` 在扫描目录时默认跳过 `example.conf`（以及旧版本留下的
`gda10_pilot.conf`）；如需提交模板本身，请显式传入该文件路径。如果复合物
文件名恰好是 `example`，生成目标会和模板同名；默认 `skip` 会保留模板并
警告，需要 `--overwrite` 才会覆盖。

---

## 5. 提交前检查

### 5.1 环境检查

```bash
/opt/desmond_md_pipeline/scripts/check_env.sh
```

登录节点没有 GPU 是正常的（会显示 WARN）；确认没有 FAIL。

### 5.2 GPU 冒烟

```bash
/opt/desmond_md_pipeline/scripts/submit_smoke.sh
```

提交一个约 10 分钟的 1-GPU PBS 作业，检查 GPU 可见性、license、Schrödinger
Python 依赖和共享目录写权限，成功时输出 `SMOKE_OK`。日志在
`$SCH_WORK_ROOT/projects/_smoke/logs/pbs/`。

### 5.3 dry-run

```bash
/opt/desmond_md_pipeline/scripts/submit_system.sh \
  "$SCH_WORK_ROOT/systems/my_sys.conf" --dry-run
```

会做完整预检（license、ASL、输入复制、配置冻结、PBS 渲染、ASCII/bash 语法
检查），然后只打印计划、不提交。注意它**不是零副作用**：会创建项目目录、
复制输入、写 `project.resolved.conf`、`system.conf.snapshot` 和
`state/run.env`。

重点检查渲染出的 `#PBS` 行、qsub 依赖链和项目路径。

---

## 6. 运行单个体系

### 6.1 正式提交

```bash
/opt/desmond_md_pipeline/scripts/submit_system.sh \
  "$SCH_WORK_ROOT/systems/my_sys.conf"
```

实际执行（job id 由 qsub 返回）：

```bash
qsub <PROJECT_DIR>/pbs/prep.<run>.pbs
qsub -W depend=afterok:<prep_id> <PROJECT_DIR>/pbs/min.<run>.pbs
qsub -W depend=afterok:<min_id>  <PROJECT_DIR>/pbs/md.<run>.pbs
qsub -W depend=afterok:<md_id>   <PROJECT_DIR>/pbs/analysis.<run>.pbs
qsub -W depend=afterok:<md_id>   <PROJECT_DIR>/pbs/mmgbsa.<run>.pbs
```

必须从**登录节点**提交；脚本检测到 `PBS_JOBID` 会拒绝。前置作业失败时，
下游不会运行。

### 6.2 监控与日志

```bash
/opt/desmond_md_pipeline/scripts/status.sh my_sys

# 需要完整队列/节点信息时再手动用 qstat/pbsnodes
qstat -u "$USER"
qstat -f -1 <jobid> | grep -E 'job_state|resources_used|comment'
```

`status.sh` 只显示项目级信息：当前阶段、已运行时间、可估算的 ETA（MD 用
chemical time + 最近 10 个 `ns/day` 的平均值），以及当前 run 的 WARN/FATAL。
它不再打印完整队列和节点/GPU 表。参数可以是体系名或项目目录绝对路径；不带
参数时扫描 `$SCH_WORK_ROOT/projects/` 下所有项目。无参数扫描中，已完成项目
只在首次完整显示一次；之后只保留一行 `N completed project(s) already
reported` 汇总，`--all` 或显式指定项目可重新查看。重新提交（新 `RUN_ID`）
后会再次提醒一次。

示例（MD 运行中）：

```
Project : my_sys
Run     : 20261116_152012_46171 (submitted 2026-11-16 15:20)
Step    : md (4/6) -- running (PBS 995), elapsed 2h 14m
Progress: 432.0 / 300000.0 ps (0.1%), avg rate 250.1 ns/day (avg10)
Log     : /home/sch/tmp/user1/desmond_md_job_my_sys/desmond_md_job_my_sys.log
ETA     : ~1d 04h; PBS walltime left 3d 21h
Warnings: 1 in this run
  [WARN] ...
Errors  : none
```

失败阶段示例：

```
Step    : min (3/6) -- FAILED (PBS 994), exit_status=1
Blocked : md analysis mmgbsa
Errors  : 1 in this run
  [FATAL] ...
Last output for min:
  logs/pbs/min.<run>.out:
    ...
```

全部完成：

```
Step    : complete (6/6), total 57m 42s
Results : results/mmgbsa_summary.md: | Mean dG_bind | ... |
Warnings: none
Errors  : none
```

说明：

- `analysis` 和 `mmgbsa` 并行；两者都未完成时会各显示一行 `Step`。
- 上游失败后，下游显示 `Blocked : ...`，不会误判为仍在排队。
- `Warnings`/`Errors` 只统计本次提交（`SUBMITTED_AT`）之后的记录；历史记录
  直接看 `logs/pipeline.log`。
- MD 运行中会先看项目目录，再查共享 scratch
  （`$HOME/tmp/$USER/desmond_md_job_<P>*/`）里的引擎日志；找到后显示 `Log`
  路径和 ETA。日志尚未出现时显示 `unknown (engine log not found yet)`，
  只给 PBS walltime 余量。
- ETA 超过 PBS walltime 余量时会额外显示
  `WARNING : ETA exceeds PBS walltime left ...`，提示作业可能在 walltime 处被停止。

日志：

| 看什么 | 路径 |
|---|---|
| PBS 标准输出 | `$SCH_WORK_ROOT/projects/<P>/logs/pbs/<stage>.<run>.out` |
| 阶段详细日志 | `$SCH_WORK_ROOT/projects/<P>/logs/<stage>_<jobid>_<time>.log` |
| MD 引擎日志 | `$SCH_WORK_ROOT/projects/<P>/desmond_md_job_<P>/desmond_md_job_<P>.log`（作业结束后可见） |

作业名会被 Torque 截断，跟踪作业请用 job id。

### 6.3 实时看 MD

Desmond 在 scratch 目录写引擎日志。scratch 位置由 `SCHRODINGER_TMPDIR` 和
站点配置决定（本集群为 `/home/sch/tmp/$USER`，可用 `SCH_SCRATCH_DIR` 覆盖；
旧的 `$HOME/tmp` 布局仍兼容），目录名包含 jobname，
按作业隔离；作业结束后日志才回传到项目目录。需要实时查看时：

```bash
qstat -n <md_jobid>          # 找节点
ssh <node> tail -f <scratch>/<jobname>.*/<jobname>.log
```

`<scratch>` 以 `SCHRODINGER_TMPDIR`/`SCH_SCRATCH_DIR`/作业日志为准。不想 ssh 就等作业结束后看
项目日志。

---

## 7. 参数变更、重跑与续跑

### 7.1 `--from`：从某阶段开始提交

```bash
/opt/desmond_md_pipeline/scripts/submit_system.sh \
  "$SCH_WORK_ROOT/systems/my_sys.conf" --from min
```

- 只提交该阶段及下游；前面的阶段不提交。
- 如果该阶段已有 `.done` 且没有 `--force`，阶段脚本会**跳过**。
- `--from analysis` 默认仍会提交 MM-GBSA；只想重跑 analysis 时加
  `--no-mmgbsa`。
- `--from mmgbsa` 只提交 MM-GBSA。

### 7.2 `--force`：归档旧结果并重跑

```bash
# 重跑 md 及下游（analysis、mmgbsa）
/opt/desmond_md_pipeline/scripts/submit_system.sh \
  "$SCH_WORK_ROOT/systems/my_sys.conf" --force md

# 重跑 analysis
/opt/desmond_md_pipeline/scripts/submit_system.sh \
  "$SCH_WORK_ROOT/systems/my_sys.conf" --force analysis

# 全部重跑
/opt/desmond_md_pipeline/scripts/submit_system.sh \
  "$SCH_WORK_ROOT/systems/my_sys.conf" --force all
```

`--force` 把旧目录重命名为 `<dir>.bak.<timestamp>`，不删除。

### 7.3 关闭分析/MM-GBSA

```bash
--no-analysis    # 不提交 RMSD 分析
--no-mmgbsa      # 不提交 MM-GBSA
```

也可以在 `.conf` 中写 `RUN_ANALYSIS=no` / `RUN_MMGBSA=no`。

### 7.4 walltime 与续跑限制

MD 的临时 checkpoint 在 scratch（位置由 `SCHRODINGER_TMPDIR` 决定）。如果
scratch 在计算节点本地，`qdel` 或 walltime 硬杀可能回传不了。**把 `PBS_WALLTIME_MD` 设得比预计 MD 时长长**（默认 96 h，300 ns
通常 18–24 h）。

本流水线在 Schrödinger 2021-2 上实测 `multisim -RESTART` 对中断的生产阶段
不可靠（`--restart-md` 仅作实验性入口）。如果目标机 walltime 上限较短，建议
拆分 MD 或与管理员商量提高 walltime。详细实测见 README 的“已知限制与管理员排错”。

---

## 8. 批量提交

```bash
# 目录下所有 *.conf
/opt/desmond_md_pipeline/scripts/submit_batch.sh "$SCH_WORK_ROOT/systems/"

# 指定多个
/opt/desmond_md_pipeline/scripts/submit_batch.sh \
  "$SCH_WORK_ROOT/systems/sys1.conf" "$SCH_WORK_ROOT/systems/sys2.conf"

# 先看计划
/opt/desmond_md_pipeline/scripts/submit_batch.sh --dry-run "$SCH_WORK_ROOT/systems/"

# 批量重跑 MD 及下游
/opt/desmond_md_pipeline/scripts/submit_batch.sh \
  --force-stage md "$SCH_WORK_ROOT/systems/"

# 批量只做 MM-GBSA
/opt/desmond_md_pipeline/scripts/submit_batch.sh \
  --from mmgbsa "$SCH_WORK_ROOT/systems/"
```

每个体系仍是一条独立的 5 作业依赖链；并发由 PBS 按 GPU 总数排队。
`systems/` 里的配置可由 `desmond-systems` 或 `init_user.sh` 自动生成（见 4.7）；
整目录提交会自动跳过 `example.conf`（以及旧的 `gda10_pilot.conf` 模板），
如需运行模板本身，请显式传入该 `.conf` 文件。

---

## 9. 各阶段做什么

| 阶段 | 做什么 | 主要输出 |
|---|---|---|
| `10_prepwizard` | `INPUT_STRUCTURE` 走 PrepWizard；`PREPARED_STRUCTURE` 直接复制并跳过 | `prepwizard/prepwizard-out.maegz` |
| `20_setup` | S-OPLS + SPC + 0.15 M NaCl + 10 Å buffer 建系 | `desmond_setup_<P>/...-out.cms` |
| `30_min` | 约 200 ps：100 ps Brownian NVT 10 K（重原子 restraint 50）+ 100 ps cfg | `desmond_min_job_<P>/...-out.cms` |
| `40_md` | 5 段 NPT 弛豫 + 生产 MD（默认 300 ns，300 K，2 fs） | MD CMS、`_trj/`、`.log`、`.cpt` |
| `50_analysis` | 按 `ALIGN_ASL` 对齐，EAF，蛋白/配体 RMSD，XLSX/PNG | `analysis/align/`、`analysis/rmsd/`、`results/` |
| `60_mmgbsa` | 最后 `MMGBSA_LAST_NS`，按 `MMGBSA_STEP_SIZE` 抽帧 | `analysis/mmgbsa/`、`results/` |

PrepWizard 的两种输入模式：

1. `INPUT_STRUCTURE`（原始 PDB/MAE/maegz）：运行

   ```bash
   prepwizard -propka_pH ... -disulfides -minimize_adj_h -label_pkas \
     -fillsidechains -fillloops -noimpref -HOST localhost -WAIT
   ```

2. `PREPARED_STRUCTURE`（已制备 MAE/maegz）：复制为
   `prepwizard/prepwizard-out.maegz`，跳过 PrepWizard，但仍会建系。

每个阶段结束都会用 `tools/validate_cms.py` 解析输出 CMS，并用
`inspect_structure.py` 检查配体/对齐 ASL 非空；min/MD 还要求引擎日志出现
`GPU Desmond started`。

---

## 10. 输出目录与验收

```
$SCH_WORK_ROOT/projects/<P>/            # P = SYSTEM_NAME
├── project.resolved.conf           # 冻结配置（种子/签名/全部参数）
├── system.conf.snapshot            # 提交时的体系配置快照
├── inputs/                         # 输入副本 + sha256.txt
├── pbs/                            # 本 run 渲染的 PBS 脚本（审计用）
├── logs/
│   ├── pipeline.log
│   ├── pbs/<stage>.<run>.out
│   └── <stage>_<jobid>_<time>.log
├── state/
│   ├── *.done
│   ├── jobs.env
│   ├── run.env
│   └── structure_report_input.json
├── prepwizard/prepwizard-out.maegz
├── desmond_setup_<P>/desmond_setup_<P>-out.cms
├── desmond_min_job_<P>/desmond_min_job_<P>-out.cms
├── desmond_md_job_<P>/
│   ├── desmond_md_job_<P>-out.cms
│   ├── desmond_md_job_<P>_trj/
│   ├── desmond_md_job_<P>.log
│   ├── desmond_md_job_<P>.cpt
│   └── *_N-out.tgz
├── analysis/
│   ├── align/aligned_<P>-out.cms + aligned_<P>_trj/
│   ├── rmsd/<P>-in.eaf、<P>-out.eaf、CSV/XLSX/PNG
│   └── mmgbsa/CSV、summary.json、summary.md
└── results/                        # 整理后的图/表
```

验收清单：

- [ ] `state/prepwizard.done`、`setup.done`、`min.done`、`md.done`、
      `analysis.done`、`mmgbsa.done`
- [ ] setup/min/MD CMS 通过 `validate_cms.py`
- [ ] min/MD 引擎日志有 `GPU Desmond started`
- [ ] MD 最终 `Chemical time` ≥ 99% 请求时长
- [ ] `desmond_md_job_<P>_trj/` 非空
- [ ] `analysis/rmsd/<P>-out.eaf`、配体 RMSD CSV/PNG、蛋白 RMSD PNG/XLSX
- [ ] `analysis/mmgbsa/summary.json` 有 n>0
- [ ] `$SCH_WORK_ROOT/results/` 有整理后的文件

---

## 11. 结果解读

### 11.1 RMSD

- **蛋白 backbone/Cα RMSD**：来自对齐后的轨迹；对齐参考就是受体主链，因此
  这个值反映内部涨落和拟合质量，不是相对初始晶体的整体漂移。
- **配体 RMSD**：每帧先按受体主链对齐，再算配体相对第一帧的重原子 RMSD，
  并考虑配体对称性。稳定的小配体通常 < 2–3 Å；持续上升可能提示跑出或构象变化。
- 短 pilot 的 RMSD 只用于确认流程能出数，不作科学结论。

### 11.2 MM-GBSA

- ΔG_bind 越负结合越有利；报告 mean ± SEM 和帧数。
- 默认最后 100 ns、step 2；帧数取决于 MD 时长和轨迹间隔。
- 轨迹含 t=0 帧：总帧数为 `floor(MD_TIME_PS / MD_TRAJ_INTERVAL_PS) + 1`。
  例如 300 ns、1 ns/帧时总帧数 301，默认窗口为最后 100 ns（start=200，
  end=301，排他）。
- `MMGBSA_START_FRAME` / `MMGBSA_END_FRAME` 显式设置时优先；`END_FRAME`
  是排他上界。
- MM-GBSA 是端点近似，不含熵；不要用绝对值直接和实验 ΔG 比较，适合同一靶点
  系列相对排序。

---

## 12. 命令与 ASL 速查

```bash
PIPELINE=/opt/desmond_md_pipeline
export SCHRODINGER=/opt/schrodinger2021-2

# 环境
"$PIPELINE/scripts/check_env.sh"
"$PIPELINE/scripts/submit_smoke.sh"

# 单体系
"$PIPELINE/scripts/submit_system.sh" "$SCH_WORK_ROOT/systems/foo.conf" --dry-run
"$PIPELINE/scripts/submit_system.sh" "$SCH_WORK_ROOT/systems/foo.conf"
"$PIPELINE/scripts/submit_system.sh" "$SCH_WORK_ROOT/systems/foo.conf" --from min
"$PIPELINE/scripts/submit_system.sh" "$SCH_WORK_ROOT/systems/foo.conf" --force md
"$PIPELINE/scripts/submit_system.sh" "$SCH_WORK_ROOT/systems/foo.conf" --no-mmgbsa

# 批量
"$PIPELINE/scripts/submit_batch.sh" --dry-run "$SCH_WORK_ROOT/systems/"
"$PIPELINE/scripts/submit_batch.sh" "$SCH_WORK_ROOT/systems/"

# 监控
"$PIPELINE/scripts/status.sh" foo
qstat -u "$USER"
qdel <id>

# 结果
"$PIPELINE/scripts/collect_results.sh"
cat "$SCH_WORK_ROOT/results/mmgbsa_summary.md"
```

如果已经 `source ~/.bashrc`，可以改用快捷命令：

```bash
desmond-check
desmond-smoke
desmond-submit "$SCH_WORK_ROOT/systems/foo.conf" --dry-run
desmond-submit "$SCH_WORK_ROOT/systems/foo.conf"
desmond-status foo
desmond-status --all
desmond-results
```

ASL 速查：

```text
chain A
res.ptype LIG
res.num 123
protein
water
ions
chain B and not (water or ions)
chain A and backbone and not (atom.ele H)
```

`inspect_structure.py` 会打印每条链/每个 HET 的原子数，并给 `chain X` 建议；
以它为准。

---

## 13. 常见问题

**Q1：换一个小分子配体怎么改？**
改 `LIGAND_ASL`（如 `res.ptype LIG` 或 `chain B`），用
`inspect_structure.py --check` 确认原子数；其他参数不用动。

**Q2：受体有多条链/配体是肽？**
`RECEPTOR_ASL` 写多条链的并集（如 `chain A or chain C`）；肽配体用独立链
（如 `chain B`）。对齐仍只用受体主链。

**Q3：结构已经制备好了？**
用 `PREPARED_STRUCTURE`（MAE/maegz），跳过 PrepWizard，但仍会建系。
注意：若同时设置 `INPUT_STRUCTURE`，`PREPARED_STRUCTURE` 优先。

**Q4：想把 300 ns 改成 100 ns？**
改 `MD_TIME_NS=100` 后重新提交。若已有完成结果，签名会变化，需要
`--force md`（归档并重跑）或新建项目。

**Q5：只想重跑 MM-GBSA？**
```bash
/opt/desmond_md_pipeline/scripts/submit_system.sh \
  "$SCH_WORK_ROOT/systems/foo.conf" --from mmgbsa --force mmgbsa
```
修改了 `MMGBSA_LAST_NS`/`STEP_SIZE` 时也应加 `--force mmgbsa`；只写
`--from mmgbsa` 且该阶段已完成时会被跳过。

**Q6：MD 被 walltime 杀了怎么办？**
2021-2 的 `multisim -RESTART` 对中断的生产阶段不可靠，**不要依赖
`--restart-md`**。优先把 `PBS_WALLTIME_MD` 设足；walltime 上限短时拆分 MD
或与管理员商量。`--force md` 会归档旧结果并从头重跑。详见 README 的
“已知限制与管理员排错”。

**Q7：多个体系怎么跑？**
一个体系一个 `.conf`，用 `submit_batch.sh "$SCH_WORK_ROOT/systems/"`；PBS 按 GPU
总数排队，每个体系一条依赖链。

**Q8：为什么 MD 日志里看不到实时进度？**
Desmond 在 scratch 目录写日志，完成才回传。需要实时看就
`qstat -n` 找节点后 ssh 到节点 tail 日志；或者等完成后看项目日志。

**Q9：为什么 `licutil -available` 显示没有 token？**
如果 license 是 uncounted/HOSTID=ANY；用
`licutil -list` 检查 feature 是否存在即可。

**Q10：为什么不能在计算节点提交？**
部分集群在计算节点 qsub 会因 `trqauthd` 失败。所有提交从登录节点发起；
脚本检测到 `PBS_JOBID` 会拒绝。

**Q11：目标机 GPU 数不同要改什么？**
不改脚本。每个 min/MD 只申请 1 卡，批量交给 PBS 排队；只需确认目标机配置了
`gpus` 资源。

**Q12：不想要 MM-GBSA？**
加 `--no-mmgbsa`，或在 `.conf` 写 `RUN_MMGBSA=no`。MD/RMSD 不受影响。

**Q13：PBS 脚本里可以有中文吗？**
不可以。PBS 脚本必须纯 ASCII；教程/日志/配置里的中文没问题，渲染后的
`.pbs` 会自动做 ASCII 检查。

**Q14：`/opt` 不能写怎么办？**
流水线不需要写 `/opt`；只有项目目录和 `$HOME/.schrodinger` 会被写。

**Q15：重新 init 到别的目录后，旧项目去哪了？**
旧项目仍留在旧工作区，不会移动。用
`/opt/desmond_md_pipeline/scripts/status.sh /旧工作区/projects/<name>` 查看，
或继续在旧工作区运行命令。新工作区只影响之后的提交。

**Q16：`source ~/.bashrc` 后还是旧 root / 别名不生效？**
如果当前 shell 已经有 `SCH_WORK_ROOT`，托管块不会覆盖它；执行
`unset SCH_WORK_ROOT && source ~/.bashrc`。别名只在交互 bash 中生效，
`ssh host desmond-status` 或脚本里请用绝对路径或显式 `export`。

**Q17：`status.sh` 为什么没有 ETA / 只显示 unknown？**
queued/running 的非 MD 阶段没有可靠进度源，只显示 elapsed 和 PBS walltime
余量。MD 会先查项目目录，再查共享 scratch
（`SCH_SCRATCH_DIR`，默认 `/home/sch/tmp/$USER`，以及旧的 `$HOME/tmp/$USER`）；
目录名形如 `desmond_md_job_<P>*/`，通常 MD 开始后
几分钟内即可显示 ETA；如果日志还没出现，会显示 `engine log not found yet`，
稍后重试即可。

**Q18：`status.sh` 的警告/错误包含旧运行吗？**
不包含。它按当前 `jobs.env` 的 `SUBMITTED_AT` 过滤，只显示本次提交之后的
`WARN`/`FATAL`；需要历史记录时直接查看 `logs/pipeline.log`。

**Q19：`status.sh` 不显示节点/GPU 了吗？**
是的。需要时手动运行 `qstat -u "$USER"`、`pbsnodes -a` 或
`qstat -f -1 <jobid>`。

**Q20：为什么 `status.sh` 不再显示已经完成的项目？**
无参数扫描把“完成”当作一次性提醒：首次完整显示后会在项目 `state/` 下记录
`status_reported.env`，之后只保留一行汇总。运行中、失败和未提交的项目始终
显示；重新提交后 `RUN_ID` 变化，会再次提醒一次。需要随时查看已完成项目时用
`desmond-status --all` 或 `desmond-status <项目名>`。

---

## 14. 共享安装使用规则

- `/opt/desmond_md_pipeline` 由管理员维护，普通用户只读；
- 每个用户使用自己的 `SCH_WORK_ROOT`，不要共享；
- 不要把 license、密钥或未公开结构放进共享代码目录；
- 用自己的账号提交 PBS 作业。

---

*最后更新：2026-11-19*
