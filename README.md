## ⚖️ 版权声明 / Copyright Notice

本项目是对 Steam 平台游戏《竞拍之王》（Bid King）核心玩法的非官方复刻，仅用于 AI 辅助游戏开发相关技术的学习与研究目的。本项目与原游戏开发者、发行方或 Steam 平台不存在任何关联、授权或背书关系。

本项目不得用于任何形式的商业用途。如本项目中的任何内容侵犯了您的合法权益，请及时与我联系。

联系邮箱：[**snoinss@gmail.com**](mailto:snoinss@gmail.com)

在收到通知并核实后，我将尽快删除或修改相关内容。

感谢您的理解与支持。

---

This project is an unofficial recreation of the core gameplay of the Steam game *Bid King* and is intended solely for learning and research purposes related to AI-assisted game development. This project is not affiliated with, endorsed by, or authorized by the original developers, publishers, or the Steam platform.

This project must not be used for any commercial purposes. If you believe that any content in this project infringes upon your legal rights, please contact me promptly.

Contact email: [**snoinss@gmail.com**](mailto:snoinss@gmail.com)

Upon receiving your notice and verifying the issue, I will promptly remove or modify the relevant content.

Thank you for your understanding and support.

---

## 竞拍之王_复刻版

本游戏是一个使用 Godot 4.2 + GDScript 开发的多人在线竞拍博弈游戏。玩家根据仓库中隐藏物品的轮廓信息进行盲拍，在有限轮次内竞争整个仓库的成交权。

## 项目简介

- 引擎：Godot 4.2
- 语言：GDScript
- 模式：Godot ENet 联机，服务器权威房间制
- 玩家人数：2 到 4 人
- 仓库规模：20 x 20
- 物品数量：每局 40 到 80 个
- 核心玩法：根据隐藏物品的占格轮廓进行整仓盲拍

## AI 开发说明

本项目在开发过程中使用了 AI 辅助编程工具参与需求落地、代码实现、联机逻辑调整、UI 调整、文档整理与导出流程辅助。

- AI 工具：OpenAI Codex
- 使用形态：Codex 桌面编码代理
- 使用模型：GPT-5

AI 主要参与的工作包括：

- GDScript 模块代码编写与重构
- Godot 场景与 UI 文案调整
- ENet 联机房间制逻辑迭代
- Windows 导出流程辅助
- README 文档整理

需要说明的是：

- AI 负责辅助开发，不代表所有设计决策完全自动生成
- 项目的功能验证、运行测试与最终版本保留，仍以本地工程实际结果为准

## 游戏核心规则
参考《竞拍之王》的核心玩法，仅实现了竞拍流程，未引入物品类型、玩家角色和技能等系统。

### 1. 仓库与物品

- 仓库为 `20 x 20` 网格。
- 每个物品只占据矩形区域。
- 物品之间不重叠、不越界。
- 玩家在对局中只能看到：
  - 仓库大小
  - 物品占用格子的轮廓
- 对局结束后会揭晓：
  - 物品品级颜色
  - 物品真实总价值

### 2. 品级与价值

品级范围：

- 红
- 黄
- 紫
- 蓝
- 绿
- 白

总价值计算方式：

- `总价值 = 单格价值 x 格数`

### 3. 竞拍轮次

最多 6 轮：

1. 第 1 轮：`> 100%`
2. 第 2 轮：`> 60%`
3. 第 3 轮：`> 40%`
4. 第 4 轮：`> 20%`
5. 第 5 轮：`> 0%`
6. 第 6 轮仍未满足则流拍

每轮：

- 所有玩家提交本轮出价
- 服务器统一公开本轮出价
- 满足规则则立即成交
- 不满足则进入下一轮

### 4. 超时规则

- 每轮有 `60 秒` 倒计时
- 超时未出价的玩家会被判定为本局淘汰
- 被淘汰后，本局后续轮次不能继续出价

### 5. 积分规则

- 赢家积分 = `仓库真实总价值 - 成交价格`
- 若高价买入低价值仓库，可能得到负分

## 联机方式

本项目为服务器权威联机：

- 房主创建房间
- 其他玩家加入房间
- 当前支持 `2 到 4` 名玩家开局
- 所有在房玩家点击“准备”后自动开始

### 本地多开测试

同一台电脑多开时：

- 房主创建房间
- 其他客户端使用 `127.0.0.1`
- 端口默认 `7000`

### 局域网联机测试

不同电脑局域网测试时：

- 房主创建房间后，状态栏会显示局域网加入地址
- 其他玩家输入该 IP 和端口加入

## 操作说明

- 创建房间：创建当前联机房间
- 加入房间：加入其他玩家的房间
- 准备：切换准备状态
- 离开房间：退出当前房间
- 出价：提交当前轮次出价

## 项目结构

```text
BidKingReplica/
├── README.md
├── project.godot
├── export_presets.cfg
├── scenes/
│   └── Main.tscn
├── scripts/
│   ├── ai/
│   │   └── AIPlayer.gd
│   ├── core/
│   │   ├── AuctionSystem.gd
│   │   ├── GameManager.gd
│   │   └── WarehouseGenerator.gd
│   ├── data/
│   │   ├── Item.gd
│   │   └── Player.gd
│   ├── network/
│   │   └── NetworkManager.gd
│   └── ui/
│       └── UIManager.gd
└── build/
    └── windows/
```

## 模块说明

### GameManager

主流程控制器，负责：

- 初始化 UI 和联机模块
- 同步回合开始、结算、结束
- 处理本地玩家交互
- 组织对局中的 UI 刷新

### AuctionSystem

负责：

- 多轮竞拍规则
- 出价公开
- 成交判定
- 流拍处理
- 排名与结算

### WarehouseGenerator

负责：

- 生成 20x20 仓库
- 生成多个矩形物品
- 保证物品不重叠
- 计算真实总价值

### Item

物品数据类，保存：

- 物品编号
- 格子列表
- 品级
- 单格价值
- 总价值

### Player

玩家数据类，保存：

- 玩家编号
- 名称
- 当前出价
- 总积分
- 是否准备
- 是否淘汰

### NetworkManager

联机核心，负责：

- ENet 建房与加入
- 房间状态同步
- 服务器权威回合推进
- 出价收集与广播
- 断线与房间重置

### UIManager

负责：

- 主界面文本与按钮
- 仓库网格绘制
- 玩家面板展示
- 竞拍记录
- 最终结果展示

## 运行方式

### 1. 使用 Godot 编辑器运行

1. 使用 Godot 4.2 打开项目根目录
2. 运行主场景 `scenes/Main.tscn`
3. 通过创建房间或加入房间开始测试

### 2. Windows 导出文件

当前仓库中已经包含导出的 Windows 可执行文件：

- `build/windows/BlindWarehouseAuction.exe`

## 导出说明

项目已配置 Windows 导出预设：

- 预设文件：`export_presets.cfg`
- 导出目标：`build/windows/BlindWarehouseAuction.exe`

若本地已安装 Godot 4 对应的 Windows Export Templates，可通过 Godot 编辑器或命令行重新导出。

## 当前特点

- 全中文 UI
- 服务器权威房间制
- 轮次倒计时与超时淘汰
- 仓库轮廓自适应缩放
- 支持窗口大小变化和窗口模式切换后的轮廓重同步

## 注意事项

- 当前版本以局域网/直连房间制为主
- 若房主断线，当前对局会被取消并返回房间
- 运行环境建议使用 Godot 4.2 或兼容的 Godot 4 版本
