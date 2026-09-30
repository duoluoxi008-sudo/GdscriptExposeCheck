---
name: expose-check
description: 检查、增删 GDScript 里暴露给外界的成员（#expose / #region expose 标记），并按蓝图 JSON 给脚本补标记或生成成员存根。当用户提到「这个类对外暴露了什么」「把某个方法/变量暴露出去」「别暴露X」「按蓝图改脚本」「导出/导入接口蓝图」「看看类的结构」时使用。
---

# ExposeCheck

在 Godot 项目里管理 **GDScript 对外的接口**：哪些成员是暴露给别的脚本用的，
以及按一份「蓝图 JSON」把这些暴露关系批量落到代码里。

判断标准很朴素：**打开一个类，一眼就能看清它对外提供了什么**。

## 何时使用

- 用户问「这个脚本暴露了什么」「XXX 类对外长什么样」→ `list` / `outline`
- 用户说「把 XXX 暴露出去」「这个别暴露」→ `expose` / `unexpose`
- 用户给了一份蓝图 JSON，要落到代码上 → `check` 先看差异，再 `apply`
- 用户要一份人能读的类结构总览 → `outline`

## 怎么调用

**不要自己写正则去解析或修改 `#expose` 标记。** 所有逻辑都在 CLI 里，它和编辑器插件
共用同一份 `script_analyzer.gd` —— 你自己解析的话，「你以为暴露的」和「插件认为暴露的」
迟早会漂移，然后就会静默地改错文件。

```bash
godot --headless --path <项目根> --script res://addons/expose_check/tools/expose_cli.gd -- <命令> [参数...]
```

| 命令 | 作用 |
|---|---|
| `list <脚本...>` | 列出脚本暴露给外界的成员（含签名和文档） |
| `outline <脚本\|蓝图.json>` | 输出 markdown 大纲，给人/AI 看 |
| `expose <脚本> <成员...>` | 给成员补 `#expose` 标记 |
| `unexpose <脚本> <成员...>` | 去掉成员的暴露 |
| `region-expose <脚本> <成员...>` | 把这批成员（第一个到最后一个）整段包进 `#region expose` |
| `region-unexpose <脚本> <成员...>` | 同上，改用 `#region unexpose` |
| `region-remove <脚本> <成员...>` | 拆掉包住这些成员的 region 标记 |
| `apply <蓝图.json> [脚本...]` | 按蓝图补标记 / 生成成员存根（**只增不减**） |
| `check <蓝图.json> [脚本...]` | 只报告差异，**绝不写文件** |
| `blueprint <脚本...> [-o 文件]` | 从脚本**反向生成**蓝图（只有节点和成员，没有连线） |

`region-expose` 是按**范围**包的：从第一个成员的声明行到最后一个成员的块尾，
**中间夹着的成员会一起被包进去**。想只包住某一个，就只给它一个名字。

`region-remove` **会改变语义** —— 里面的成员失去 region 的庇护就不再暴露了。
它不是纯格式改写，用之前想清楚。

路径可以写 `res://` 全路径，也可以写相对项目根的路径。
退出码：`0` = 全部成功，`1` = 有失败（错误走 stderr）。

### ⚠️ 一跑就崩（signal 11）时先看这里

Godot 启动时要往 `user://` 写日志，Windows 上是
`%APPDATA%\Godot\app_userdata\<项目名>\logs\`。

**如果是从带文件沙箱的进程里跑 CLI**（某些 AI 代理就是这样），这个目录在允许写入的
范围之外 → 目录建不出来 → Godot **直接段错误崩掉**。而且它崩在「加载项目」阶段，
和你的参数、脚本都没关系，很容易误判成项目坏了：

```
ERROR: Could not create directory: 'user://logs'.
   at: make_dir_recursive (core/io/dir_access.cpp:179)
CrashHandlerException: Program crashed with signal 11
```

**解法：把 `user://` 指到能写的地方**，也就是覆盖 `APPDATA`：

```powershell
$env:APPDATA = "<项目根>/.godot_userdata"
godot --headless --path <项目根> --script res://addons/expose_check/tools/expose_cli.gd -- <命令>
```

```bash
APPDATA=<项目根>/.godot_userdata godot --headless --path <项目根> --script ... -- <命令>
```

或者干脆让 CLI 在沙箱外跑（普通终端）。

另外：这个项目自己的 `Core/Entity/StateMachine/PlaneStateMachine/PlaneState.gd`
**有一批 2D/3D 类型不匹配的解析错误**，headless 加载时会刷屏。那是游戏代码本身的问题，
和 CLI 无关 —— 过滤掉这些噪音再看输出。

**改了脚本之后**要提醒用户：编辑器里那些节点会变**红**（md5 对不上了），
在图上点「刷新」按钮就重新分析。**不会自动重建**，这是有意设计的。

## 标记语义（必须理解，否则 `unexpose` 会做错）

```gdscript
#expose           管紧跟着它的那一个声明（中间可以隔空行、注释、注解）
#unexpose         同上，表示这一个不暴露
#region expose    管整个区域，直到配对的 #endregion
#region unexpose  同上，表示这一片都不暴露
#endregion        关掉最近打开的那个 region（和 if/else 一样按栈配对）
```

优先级：

1. **单行标记 > region**。在 `#region expose` 里写一行 `#unexpose`，那个成员就不暴露。
2. **嵌套时内层优先**。`#region expose` 里套 `#region unexpose`，内层成员不暴露；
   碰到内层的 `#endregion` 自动回到外层状态。

标记是**大小写不敏感**的（`#EXPOSE` / `#Expose` 都行），但 `#exposed`、`#expose_region`
**不是**标记（后面多字符就不算）。`# region`（`#` 后有空格）也不算。

### 因此「取消暴露」有三种情况

如果只是把 `#expose` 那一行删掉，**在 region 里的成员根本不会变得不暴露**。CLI 会自动分流：

- 成员紧邻上方有它自己的 `#expose` → 删掉那一行
- 成员是靠 `#region expose` 暴露的 → 在它上方插一行 `#unexpose` 挡掉
- 本来就没暴露 → 什么都不做

## 只增不减

`apply` **只往脚本里加东西，绝不删用户手写的任何标记**。蓝图里没有但脚本里有暴露的成员，
原样保留，不碰。

### 重名怎么办

蓝图要的成员脚本里已经有了：

1. 不重复声明
2. 如果它原来没暴露 → 补一个 `#expose`
3. **把蓝图版本的存根整段注释掉，紧挨着已有成员（整个块之后）放**，当作备注
4. 在输出里报出来

这样既不会覆盖用户已经写好的实现，又不会把「蓝图原本想要什么写法」这个信息丢掉。

## 能生成什么、不能生成什么

| 种类 | 能否生成存根 |
|---|---|
| 函数 / 静态函数 / 抽象函数 | ✅ 签名（参数表 + 返回类型 + 注解）从蓝图原样抄回去 |
| 信号 | ✅ 含参数表 |
| 变量 | ✅ 含显式类型和注解（`@export` 等） |
| **常量** | ❌ 值凭空造不出来 —— 只报告，请用户手工补 |
| **枚举** | ❌ 同上 |
| 内部类 | ❌ 它是独立节点，不在存根范围 |

## 蓝图 JSON

版本 `format_version: 3`。

**老版本会自动迁移**：

- **v1 → v2**：补空的 `port_definitions` 和每个节点的 `members`。v1 压根没存这两样，
  所以端口定义是真的丢了；成员信息之后可以用 CLI 重新分析脚本补回来。
- **v2 → v3**：成员的 `"kind"` 从中文显示名改成 **ASCII id**（`"函数"` → `"func"`），
  `port_types` 的键（`"种类\t成员名"`）也跟着一起换。

版本号是 `0`、比当前还新、或者中间有跳不过去的版本，会**直接拒绝读入** ——
宁可报错，也不按错的格式解析出一堆垃圾。

### 成员种类 id

| id | 中文显示名 | 英文显示名 |
|---|---|---|
| `const` | 常量 | Constant |
| `enum` | 枚举 | Enum |
| `signal` | 信号 | Signal |
| `var` | 变量 | Variable |
| `func` | 函数 | Function |
| `ab_func` | 抽象函数 | Abstract Func |
| `static_func` | 静态函数 | Static Func |

**`kind` 一律是上面这个 ASCII id，不是显示名。** 唯一真相是
`ui/script_info.gd` 里的 `ExposeCheck_ScriptInfo.KIND_TABLE`（编辑器 UI、蓝图、CLI 都读它）。

```json
{
  "format_version": 3,
  "port_definitions": [ {"left":"受伤","right":"来源","color":"#ff8800ff"} ],
  "nodes": [ {
    "key": "res://Core/Entity/Player.gd",
    "script_path": "res://Core/Entity/Player.gd",
    "inner_name": "", "class_name": "Player", "script_md5": "…",
    "position": [0,0], "size": [220,300],
    "port_types": { "func\ttake_damage": 2 },
    "members": [ {"kind":"func","name":"take_damage","hint":"受伤",
                  "params":["amount: int"],"ret_type":"bool","prefix":""} ]
  } ],
  "links": [ { "from": {...}, "to": {...}, "semantic": "user" } ],
  "view": { "zoom": 1.0, "scroll": [0,0] }
}
```

几个要点：

- 连线端点存的是**语义**（节点 key + 成员种类/名字 + 左右），**不存端口号** ——
  端口号会随成员增删整体漂移，存了就必然错连。端点的 `kind` 同样是 ASCII id，
  固定行（父类那种）的 `kind` 为空字符串。
- 颜色是 `#rrggbbaa` 十六进制字符串，不是 Color 对象（JSON 存不了 Color）。
- `port_types` 里的数字是**端口类型**：

  | 端口类型 | 含义 |
  |---|---|
  | `0` | 父类专属，只有 FatherSolt 那一行用，成员行不许用 |
  | `1` | 默认创建时的类型，**独立的一种，没有对应设置项** |
  | `t`（≥ 2） | 设置面板的第 `t - 1` 行（界面上标着 `t-1:` 的那行），数组 index `t - 2` |

  注意别把两个「1」搞混：设置面板上标 `1:` 的是**第 1 行定义**，它对应**端口类型 2**。
  端口类型 `1` 是「默认」，设置里查不到。

## 护栏（写文件时）

- 先备份成 `<脚本>.bak`
- **写之前再算一次 md5**：和读进来时不一致就放弃写入（说明编辑器/人刚改过）
- **只做行级插入 / 删除 / 注释**，绝不整文件重写 —— 否则用户的排版、空行、注释全没了
- 幂等：已经是想要的就不动，重复调用不会叠加标记
- 保持原文件的缩进风格（Tab 还是空格）和文件末尾换行

## 不能做的事（别承诺）

- **连线写不回脚本**。蓝图里的 `links` 是图上的关系，GDScript 源码里**没有对应物**。
  只能改暴露标记，不能改连线。
- 反向也不行：从脚本**只能生成节点，生成不了连线**（连线是用户在图上表达的意图）。
- 生成存根后**要让用户过一眼**：抽象函数的 `@abstract`、常量的值、枚举的成员，
  这些光靠名字和类型是还原不出来的。

## 典型流程

**看一个类对外什么样**
```bash
godot --headless --path . --script res://addons/expose_check/tools/expose_cli.gd -- outline Core/Entity/Player.gd
```

**把两个方法暴露出去**
```bash
godot --headless --path . --script res://addons/expose_check/tools/expose_cli.gd -- expose Core/Entity/Player.gd take_damage heal
```

**按蓝图落代码**（先看差异，再动手）
```bash
godot --headless --path . --script res://addons/expose_check/tools/expose_cli.gd -- check blueprint.json
godot --headless --path . --script res://addons/expose_check/tools/expose_cli.gd -- apply blueprint.json
```

改完提醒用户：编辑器里对应节点会变红，点「刷新」即可。
