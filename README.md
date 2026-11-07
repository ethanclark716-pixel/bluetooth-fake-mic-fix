# 无麦克风蓝牙音箱导致语音输入全链路静音：WirePlumber 0.4 "假麦克风"劫持的排查与按设备修复

> **一句话**：无麦蓝牙音箱连上后，语音输入永远静音——不是音箱坏了，也不是输入法坏了，是 WirePlumber 的两个策略脚本"合作"把录音流搬到了一个纯静音的假麦克风上。本文给出**只影响单个设备**的修复方法（4 行 Lua 补丁），不需要断开音箱、不影响其他蓝牙耳机、不用改任何程序。
>
> **English TL;DR**: On WirePlumber 0.4.x, connecting an HFP-capable but microphone-less Bluetooth speaker silently hijacks recording streams tagged `media.role=Communication` (e.g. voice input) to a digital-silence "fake mic" node, even when another input device is explicitly selected. Root cause: `policy-bluetooth.lua` auto-switches the card to the headset profile, then `intended-roles.lua` writes a `target.node` metadata that overrides client targets. Fix: shadow `intended-roles.lua` in `~/.config/wireplumber/scripts/` with a 4-line guard skipping that device's source node. Works per-device, verified on Linux Mint 22.3.

## 现象

- 无麦克风蓝牙音箱（本例 Q38-1，支持 HFP 协议）连上电脑后，语音输入按快捷键说话，**识别永远为空**
- 其他程序录音一切正常；系统声音设置里默认输入就是内置麦克风，显式指定也一样无效
- **断开蓝牙立刻恢复**
- 识别端拿到的音频是纯数字静音（6 秒音频峰值 94 / 满量程 32767）

**环境**：Linux Mint 22.3（Ubuntu 24.04 noble）/ PipeWire 1.0.5 / **WirePlumber 0.4.17** / Cinnamon + X11。受害应用：任何带"通信"角色的录音流（本文是 [Vinput](https://github.com/xifan2333/fcitx5-vinput) 语音输入，其他同类应用同理）。

## 根因：三层机制"合作"完成了劫持

| 步骤 | 谁干的 | 逻辑 |
|---|---|---|
| ① 打标签 | 录音应用 | 录音流带 `media.role = Communication`（语音输入归为通信类，标签本身没错） |
| ② 切档 | `policy-bluetooth.lua` | Ubuntu 默认配置 `media-role.use-headset-profile = true`，见到"通信"流就把声卡切到 HFP 档 → **无麦音箱凭空出现一个输入节点（纯静音的"假麦克风"）** |
| ③ 抢流 | `intended-roles.lua` | 假麦克风节点带着驱动写的 `device.intended-roles = "Communication"`；脚本一匹配，就往流上写元数据 `target.node = 假麦克风`。**这条元数据的优先级高于应用自己指定的目标** |

第 ③ 步是致命的：就算你在系统里钉死内置麦克风，流还是会被元数据搬走。浏览器类应用没中招，是因为它们录音时不打 `media.role` 标签，绕过了第 ③ 步。

## 排查弯路（每条失败原因都不同，对后来人这部分最值钱）

| 尝试 | 为什么无效 |
|---|---|
| 显式钉死录音设备（`vinput device use` / pw-record `--target`） | 元数据 `target.node` 优先级高于客户端指定 |
| 对 `bluez_input.*` 节点设 `node.disabled = true` | 0.4 的 `bluez_monitor.rules` 作用在 device 层，管不到 node |
| 全局关闭 `media-role.use-headset-profile` | 有效，但**全局**开关——所有蓝牙耳机的自动切档（含正常耳机）全废，不可接受 |
| 按 MAC 对音箱设 `bluez5.roles = "[ a2dp_sink a2dp_source ]"` 去掉耳麦能力 | **pipewire 1.0.5 的 SPA 不支持按设备设置 roles**（只认全局），档位枚举层根本不认这个值 |
| 想清掉节点上的 `device.intended-roles` 属性 | 属性是 PipeWire 蓝牙驱动（SPA，C 代码）在创建节点时写的，挂在 pw-global 层，0.4 的任何配置层都够不到 |

**排查方法论（写给同样用 AI 折腾系统的人）**：

1. **先取证据，再改配置**。上一次排查连改三轮配置之后才想起来看日志，顺序反了。
2. **验证标准必须客观**。"重启后看着好了"是假象——重连音箱会恢复 A2DP 档，假麦克风暂时消失，跟规则生没生效无关。判定只看一个硬指标：**设备可用档位列表里 `headset-head-unit-msbc` 还在不在**。
3. **让 AI 用命令行自测**（`pw-record` + `pw-dump` 检查元数据和链接落点），不要人肉反复按快捷键。
4. 失败的尝试要记下**失败原因**，否则下一个 AI（或下一个自己）会原样再踩一遍。

## 解法：官方脚本遮蔽机制 + 4 行守卫

WirePlumber 0.4 加载 Lua 脚本时按 **`~/.config/wireplumber/scripts/`（用户级）→ `/etc/wireplumber/` → `/usr/share/wireplumber/`** 的顺序查找（源码 `module-lua-scripting/module.c` 的 `find_script()`，0.4.17）。同名文件用户级优先——这是官方机制，不是野路子。

做法：把系统的 `intended-roles.lua` 复制到用户级目录，在路由函数开头加一个**只匹配这一台设备**的守卫：

```lua
local function routeUsingIntendedRole(stream, dev)
  -- [本地补丁] 无麦蓝牙音箱的 HFP 输入节点是"假麦克风"，不参与"通信"抢流；
  -- 其余设备行为与原版完全一致。回滚：删除本文件后重启 wireplumber。
  if dev.properties["media.class"] == "Audio/Source"
      and (dev.properties["node.name"] or ""):find("23_CF_F0_21_FD_2A") then
    return
  end
  -- ↓ 以下与系统原版完全一致
  ...
```

（`23_CF_F0_21_FD_2A` 换成你的音箱 MAC，`:` 换成 `_`。完整文件见本仓库 [`intended-roles.lua`](intended-roles.lua)。）

**效果**：假麦克风节点还在（HFP 档还会切），但调度脚本对它视而不见——录音流老老实实走你指定的内置麦克风。正是 Windows 下同场景的行为：节点存在，无人调用。

**为什么这不算"全局开关"**：守卫只匹配一个 MAC 地址的输入节点。HONOR 耳机等其他蓝牙设备的抢流行为与原版逐字一致，耳麦自动切换也照常工作。

## 验证方法（全命令行，不需要人对着麦克风反复说话）

```bash
# 1. 后台录 6 秒，模拟"通信"角色的录音流
pw-record --media-role Communication --rate 16000 --channels 1 --format s16 /tmp/test.raw &

# 2. 录音期间用 pw-dump 检查三件事：
#    a) 假麦克风节点（bluez_input.<MAC>.*）是否出现（切档发生）
#    b) metadata "default" 里有没有把 target.node 指向假麦克风（修复前：有；修复后：无）
#    c) 录音文件 RMS 是否 > 0（假麦克风是纯数字 0，真麦克风有环境噪声底）
```

修复前实测：元数据把流指到假麦克风，音频峰值 94（≈静音）。修复后实测：假麦克风节点存在、元数据无、RMS 9772 / 峰值 32768（真实人声级）。

## 适用范围与注意事项

- 适用于 **WirePlumber 0.4.x**（Lua 配置机制）。0.5 起配置格式整体更换，本补丁自然失效——但 0.5 支持按设备 `monitor.bluez.rules` + `update-props`，届时这类需求有正规解法。Linux Mint 23（基于 Ubuntu 26.04）会自带新栈，升级后**删除补丁文件**即可。
- 补丁是系统脚本的本地副本，WirePlumber 小版本升级不会自动同步新版脚本内容；升级后可对比一下 `/usr/share/wireplumber/scripts/intended-roles.lua` 是否有变化。
- 回滚：删除 `~/.config/wireplumber/scripts/intended-roles.lua` + `systemctl --user restart wireplumber`。
- 原理上任何"应用录音被无麦蓝牙设备抢走"的场景都适用，不限 Vinput。

## 协议与声明

- 应用侧背景：本问题的受害应用是 [Vinput](https://github.com/xifan2333/fcitx5-vinput)（Fcitx5 语音输入插件）+ 自研的[讯飞输入法非官方协议 provider](https://github.com/xifan2333/vinput-registry)（PR #97）。
- 修复思路与排查由 AI 模型 GLM-5.3（智谱）完成初版，经人工复核、真机验收后整理成文。失败尝试的记录同样由 AI 整理，未做推测性描述。

## 关键词

`WirePlumber 0.4` `蓝牙` `HFP` `假麦克风` `静音` `无麦音箱` `免手操作` `media.role` `Communication` `intended-roles` `target.node` `语音输入` `pw-record` `Linux Mint` `PipeWire` `voice input silence` `bluetooth fake microphone`
