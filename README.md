# ExposeCheck

**中文** | [English](README.en.md)

> 把 GDScript 的对外接口画成图 —— 打开一个类，一眼看清它对外提供了什么。

ExposeCheck 是一个 Godot 编辑器插件。它分析你的脚本，把每个类画成图上的一个节点，
列出**真正暴露给外界**的成员，并把类与类、内部类与父类之间的关系用连线表达出来。

暴露哪些成员**完全由显式标记决定**（`#expose` / `#region expose`），
不存在"默认全都暴露"

---

## 特性

- **接口可视化** — 每个类一个 GraphNode，逐个列出暴露的信号 / 变量 / 函数 / 常量 / 枚举，
	带上参数表、返回类型和 `##` 文档
- **继承链自动补齐** — 扔进来一个类，它的自定义父类会自动往左边排开并连线，一直到原生类为止
- **内部类也是类** — 暴露的内部类会生成自己的节点（标题形如 `主类:内部类`），可以再嵌套
- **蓝图导出 / 导入** — 整张图（含端口定义、成员签名、连线）存成一份 JSON，可版本控制、可分享
- **脚本改动标脏** — 磁盘上的脚本一变，对应节点立刻变红；点刷新就重新分析，**绝不自动重建**
- **会话自动保存** — 关掉编辑器时自动存档，下次打开自动恢复，不用重新摆一遍
- **端口类型** — 端口按类型分组，只有同类型的端口才能连；类型 0 留给父类边
- **命令行工具** — 附一个 headless CLI，可以批量检查、增删暴露标记、按蓝图改脚本
- **配套 AI Skill** — 见 [`SKILL.md`](SKILL.md)，让 AI 助手安全地代你操作这些标记

## 环境要求

**Godot 4.7 或更高版本。**

插件使用了 4.7 才引入的 `EditorDock` / `EditorPlugin.add_dock()`
（旧的 `add_control_to_dock()` 在 4.7 已弃用）。在 4.6 及更早版本上无法加载。

## 安装

**从 Asset Library**：编辑器里 `AssetLib` 标签页搜索 "ExposeCheck"，安装后
`项目 → 项目设置 → 插件` 里启用。

**手动**：把 `addons/expose_check/` 整个目录拷进你的项目，然后在
`项目 → 项目设置 → 插件` 里勾选 **ExposeCheck**。

启用后编辑器的底部面板会出现一个 **ExposeCheck** 停靠面板。

## 快速上手

1. 在图上**右键 → 新建节点**，选一个 `.gd` 脚本
2. 节点出现，它的自定义父类会自动往左排开
3. 把鼠标放到成员行上，**左键**看它的 `##` 文档，**右键**给它选一个端口定义
4. **右键拖拽**端口连线（只有同类型的端口连得上），手动连出接口关系
5. 顶部「导出」存成蓝图 JSON

## 暴露须知

ExposeCheck **只看标记**。想让一个成员对外可见，就在它上面写一行标记：

```gdscript
#expose
func take_damage(amount: int) -> bool:
	return true

## 这一行是文档，会显示在节点上
#expose
var hp: int = 100
```

### 标记一览

| 标记 | 作用 |
|---|---|
| `#expose` | 管紧跟着它的那**一个**声明（中间可以隔空行、注释、注解） |
| `#unexpose` | 同上，表示这一个**不**暴露 |
| `#region expose` | 管**整个区域**，直到配对的 `#endregion` |
| `#region unexpose` | 同上，表示这一片都**不**暴露 |
| `#endregion` | 关掉最近打开的那个 region（和 `if/else` 一样按栈配对） |

### 优先级

1. **单行标记压过 region** —— 在 `#region expose` 里写一行 `#unexpose`，那个成员就不暴露
2. **嵌套时内层优先** —— `#region expose` 里套 `#region unexpose`，内层成员不暴露；
	 碰到内层的 `#endregion` 自动回到外层状态

标记**大小写不敏感**（`#EXPOSE` / `#Expose` 都行）。但 `#exposed`、`#expose_region`
**不是**标记（后面多字符就不算），`# region`（`#` 后有空格）也不算。

### 文档注释

声明上方或标记上方的 `##` 注释都会成为该成员的文档，在节点上显示。
鼠标左键点成员行就能看到全文。

## 端口类型

每个成员行左右两端都是端口，端口有**类型**，**只有类型相同才连得上**。

| 端口类型 | 含义 |
|---|---|
| `0` | **父类专属**。只有节点的 FatherSolt 那一行用，成员行不许用 |
| `1` | **默认创建时的类型**。它是独立的一种，**不对应「设置」面板里的任何一行** |
| `t`（≥ 2） | 「设置」面板里的第 `t - 1` 行（界面上标着 `t-1:` 的那行） |


在「设置」面板里添加端口定义（左右含义 + 颜色），然后在图上的成员行上右键选一个，
那个成员行的端口颜色和类型就会跟着变。改了类型导致已有连线失效时，插件会**自动断开**那些线并提示。

## 蓝图（导出 / 导入）

蓝图是一份 JSON，描述整张图：

```json
{
	"format_version": 3,
	"generator": "expose_check",
	"port_definitions": [ {"left": "受伤", "right": "来源", "color": "#ff8800ff"} ],
	"nodes": [ {
		"key": "res://Core/Entity/Player.gd",
		"script_path": "res://Core/Entity/Player.gd",
		"inner_name": "", "class_name": "Player", "title": "Player",
		"script_md5": "…", "position": [0, 0], "size": [220, 300],
		"port_types": { "func\ttake_damage": 2 },
		"members": [ {"kind": "func", "name": "take_damage", "hint": "受伤",
									"params": ["amount: int"], "ret_type": "bool", "prefix": ""} ]
	} ],
	"links": [ { "from": {…}, "to": {…}, "semantic": "user" } ],
	"view": { "zoom": 1.0, "scroll": [0, 0] }
}
```

几个设计要点：

- **连线端点存语义** —— 端口号会随成员增删整体漂移，端点记的是「哪个节点的哪个成员，左还是右」
- **`kind` 是 ASCII id**（`func` / `var` / `signal` / `const` / `enum` / `ab_func` / `static_func`），
	不是中文显示名 —— 蓝图是交换格式，不能带本地化文本。种类表的唯一真相是
	`ui/script_info.gd` 里的 `ExposeCheck_ScriptInfo.KIND_TABLE`
- **老版本会自动迁移** —— v1 → v2 补空的端口定义和成员列表；v2 → v3 把 `kind`
	和 `port_types` 的键从中文换成 ASCII id（都会打警告）
- 版本号是 `0`、比当前新、或中间跳不过去的，**直接拒绝读入**（宁可报错，也不按错的格式解析）
**导出**存图上全部节点；**保存选中节点**只存选中的那部分（+两端都在集合里的连线）。
**导入**时每次都会问你：清空重建，还是合并进现有图。

## 刷新与脏标记

- 插件**从不自动重建节点** 
- 当你改动脚本并**保存后**，对应节点右侧的状态灯变**红**
- 点节点上的「刷新」按钮，或顶部「刷新所有节点」，它才重新分析
- 刷新会**保留**你选过的端口定义和手工连的线（按成员身份重新接回去；成员没了的线会被丢弃并给出警告）

## 会话自动保存

关闭编辑器时，插件把整张图和端口定义存到 `addons/expose_check/auto_save/session.json`；
下次打开编辑器自动读回来。

放在**插件自己的目录**里，所以：
- 不想让它进版本库的话，在 `.gitignore` 里加一行 `addons/expose_check/auto_save/`

那个目录里有一个 `.gdignore`，Godot 不会去扫描它,所以不会在godot编辑器里面看到他，要显示就删掉。

## 命令行工具 & AI Skill

`tools/expose_cli.gd` 是一个不依赖编辑器的 headless 工具，和插件**共用同一份分析器**：

```bash
godot --headless --path <项目根> \
	--script res://addons/expose_check/tools/expose_cli.gd -- <命令> [参数...]
```

| 命令 | 作用 |
|---|---|
| `list <脚本...>` | 列出脚本暴露的成员（含签名和文档） |
| `outline <脚本\|蓝图.json>` | 输出 markdown 大纲 |
| `expose` / `unexpose <脚本> <成员...>` | 增删单个成员的标记 |
| `region-expose` / `region-unexpose <脚本> <成员...>` | 把一批成员整段包进 region |
| `region-remove <脚本> <成员...>` | 拆掉包住这些成员的 region |
| `apply <蓝图.json> [脚本...]` | 按蓝图改脚本（**只增不减**） |
| `check <蓝图.json> [脚本...]` | 只报告差异，不写文件 |
| `blueprint <脚本...> [-o 文件]` | 从脚本反向生成蓝图（只有节点和成员，没有连线） |

写文件时的护栏：先备份成 `<脚本>.bak`；**写之前再算一次 md5**，和读进来时不一致就放弃
（说明编辑器里刚改过）；**只做行级插入/删除/注释**，绝不整文件重写；幂等。

配合 [`SKILL.md`](SKILL.md) 可以让 AI 助手代你操作这些标记。

> **headless 跑不起来？** Godot 启动要往 `user://logs/` 写日志。如果 CLI 是从带文件沙箱的
> 进程里跑的（某些 AI 代理就是这样），那个目录在工作区外 → 建不出来 → Godot 直接**段错误**，
> 而且崩在加载项目阶段，看起来像项目坏了。解法是把 `user://` 指到可写处：
> `APPDATA=<项目根>/.godot_userdata godot --headless ...`。详见 `SKILL.md`。

## 目录结构

```
addons/expose_check/
├── plugin.cfg                     插件清单
├── expose_check_plugin.gd         EditorPlugin：挂载停靠面板 + 会话保存/恢复
├── icon.svg                       插件图标（停靠面板用）
├── icon.png                       同一张图的 128×128 位图，Asset Library 列表图用
├── LICENSE
├── README.md                      中文说明（本文件）
├── README.en.md                   英文说明
├── SKILL.md                       AI Skill 说明
├── auto_save/
│   ├── .gdignore                  让 Godot 别去扫描这个目录
│   └── session.json               会话快照（关闭编辑器时自动写入）
├── tools/
│   └── expose_cli.gd              headless CLI
└── ui/
		├── ExposeCheckPanel.tscn      主面板场景
		├── expose_check_interface.gd  面板根节点：常驻弹窗、右键菜单
		├── i18n.gd                     界面本地化（中文原文当 key）
		├── expose_check_area.gd       GraphEdit：节点/连线/蓝图/刷新
		├── ScriptNode.tscn/.gd        图上代表一个类的节点
		├── ContainerBlock.tscn/.gd    节点里代表一个成员的行
		├── ConfigPanel.gd             端口定义的「设置」面板
		├── InputLine.tscn/.gd         设置里的一行
		├── script_analyzer.gd         源码分析（唯一真相，CLI 也用它）
		├── script_info.gd             一个类的分析结果
		├── expose_name_and_dsharp_hint.gd  一个成员的记录（名字/文档/签名）
		├── PortInfo.gd                一条端口定义
		├── blueprint_io.gd            蓝图 JSON 的读写与版本迁移
		├── member_writer.gd           标记增删与代码存根生成
		└── popup_helper.gd            弹窗坐标换算
```

## 已知限制

- **常量和枚举不能自动生成代码存根** —— 它们的值是凭空造不出来的，CLI 只会报告出来让你手工补
- **连线写不回脚本** —— 蓝图里的连线是你在图上表达的意图，GDScript 源码里**没有对应物**。
	反过来也一样：从脚本只能生成节点和成员，生成不了连线
- 生成代码存根后**请过一眼** —— 抽象函数的 `@abstract`、常量的值这些，光靠名字和类型还原不出来
- 删掉一个子类节点后，它的父类节点会留在图上（没有自动清理无引用祖先）

## 语言 / Language

**编辑器界面**跟随 Godot 的编辑器语言（`编辑器设置 → 界面 → 编辑器语言`）：

- 中文系（`zh_*`）→ 中文
- **其它一律英文**

**命令行工具固定输出英文** —— 它常在 CI / 管道里跑，机器解析输出时不该受界面语言影响。

### 加一门语言

编辑 `ui/i18n.gd` 里的 `TABLE`，照着 `"en"` 加一项就行：

```gdscript
const TABLE := {
	"en": { "设置": "Settings", ... },
	"ja": { "设置": "設定", ... },      # ← 新增
}
```

机制是**拿中文原文当 key**，所以：

- **`.tscn` 场景文件一个字都不用改** —— 界面文本靠 `ExposeCheck_I18n.apply(self)`
	在面板 `_ready` 时统一替换
- 运行时动态生成的文案，在赋值那行调 `ExposeCheck_I18n.t("中文原文")`
- 漏翻不会变成空白，只会露出中文，一眼看得出来

### 为什么不用 Godot 标准的 TranslationServer

试过了，**在这个版本上对编辑器插件不可靠**（Godot 4.7.1 实测）：
`TranslationServer.add_translation()` 注册成功、`get_translation_object()` 也拿得到那条消息，
但 `TranslationServer.translate()` 和 `Control.atr()` **都不用**它 ——
连编辑器自己的字符串（`translate("Import")`）也是原样返回，`loaded_locales` 初始为 `[]`。
换 ASCII key、换 `StringName`、切 locale、把 `Translation` 存成 `.tres` 再加载，结果全都一样。

所以这里自带一张表。副作用是**不需要 `.po` 工具链**，加语言只是加一个字典条目。

## 许可证

[MIT](LICENSE) © 2026 Douluoxi
