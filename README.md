# 点击驱散 ClickCleanse

小队一键驱散助手：在每位队友血条旁放一个可点击的小方块，出现你能驱散的减益时，方块自动变成对应类型的颜色并亮起白色描边，点一下即对该队友施放驱散。
A one-click party dispel helper: a clickable square sits beside each party member's health bar; when a debuff you can dispel appears, the square turns the matching type color with a white highlight border, and one click casts the dispel on that member.

## 功能 / Features

- 自动识别你当前职业、专精可用的驱散技能并绑定到鼠标键：1 个技能绑左键，2 个绑左/右键，3 个绑左/右/中键；切换专精或天赋后自动重新识别。
  Auto-discovers the dispels available to your class and spec and binds them to mouse buttons: 1 dispel → left click, 2 → left/right, 3 → left/right/middle; re-detects after spec or talent changes.
- 队友身上没有可驱散减益时，方块只显示中央一圈淡白色印记；出现可驱散减益时整块变色并亮起白色外描边，战斗中、副本内同样有效（基于 12.1 官方托管光环方案，不受保密光环限制）。
  When clean, the square shows only a faint white mark in the center; when a dispellable debuff appears, the whole square turns the type color with a lit white border — works in combat and instances (built on the official managed aura system, unaffected by the 12.1 secret-aura restrictions).
- 减益类型颜色图例 / Debuff type color legend:

  | 类型 Type | 颜色 Color | | 类型 Type | 颜色 Color |
  |---|---|---|---|---|
  | 魔法 Magic | 天蓝 Sky blue | | 疾病 Disease | 明黄 Yellow |
  | 诅咒 Curse | 亮紫 Purple | | 流血 Bleed | 明红 Red |
  | 中毒 Poison | 亮绿 Green | | | |

- 显示驱散技能冷却（转圈动画与倒计时数字，公共冷却和真实冷却都会显示）。
  Shows dispel cooldowns (sweep animation and countdown numbers, covering both GCD and the real cooldown).
- 悬停方块可查看队友姓名（按职业染色）与当前的按键绑定。
  Hover a square to see the party member's name (class-colored) and the current button bindings.
- 单人与小队中启用，进入团队自动隐藏；当前专精没有驱散能力时自动停用，几乎不占用任何资源。设置（方块大小、停靠位置）保存在账号下，所有角色共享。
  Active solo or in a party, hidden in raids; disables itself when your spec has no dispel, at near-zero cost. Settings (square size and docking position) are saved account-wide and shared across characters.

## 指令 / Commands

```
/ccl left|right|top|bottom    设置方块相对血条的停靠位置（默认 left）
                               Dock the square left/right/above/below the health bar (default left)
/ccl 10-100                   设置方块大小（默认 30）
                               Set the square size (default 30)
```

## 兼容性 / Compatibility

- 对 Ellesmere Raid Frames (ERF) 与暴雪原生小队框架做了专门适配；其他标准单位框架（如 ElvUI）通常也能自动识别。
  Specially adapted for Ellesmere Raid Frames (ERF) and the default Blizzard party frames; other standard unit frames (e.g. ElvUI) are usually auto-detected too.
- 仅在小队（含单人）中工作，团队中自动隐藏。
  Works in parties (including solo) only; automatically hidden in raids.

## 致谢 / Credits

本插件的实现参考了以下插件，感谢它们的作者：
The implementation of this addon references the following addons — many thanks to their authors:

- [Decursive](https://www.curseforge.com/wow/addons/decursive) — 托管光环容器（AuraContainer）方案
  Referenced for the managed aura overlay (AuraContainer) approach.
- [SmartDeBuff](https://www.curseforge.com/wow/addons/smartdebuff) — 驱散类型颜色映射（ColorCurve）方案
  Referenced for the dispel-type color mapping (ColorCurve).
- Ayije_CDM — 冷却的 DurationObject 引擎渲染方案
  Referenced for the DurationObject-based cooldown rendering.
- ActionbarEnhanced — 倒计时数字字体的应用技巧
  Referenced for the countdown-number font technique.

作者自用的单位框架插件：Ellesmere Raid Frames。
The unit frame addon the author uses: Ellesmere Raid Frames.

## 说明 / Note

本插件为作者个人游玩方便而制作，功能以自身需求为准，不承诺长期维护。
This addon was made for the author's personal convenience; features follow personal needs and long-term maintenance is not guaranteed.
