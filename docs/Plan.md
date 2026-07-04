# LiquidCode → TOKENICODE 原生化完整改造计划

## Summary

- **目标**：保留 LiquidCode 产品身份，做成与 TOKENICODE v0.11.0
  功能完整、布局同构、可实际使用的 macOS 原生 Liquid Glass app。
- **当前基线**：Xcode 单元测试已通过 38/38，但 docs 仍标记
  9 个 `PARTIAL`；现有 UI 截图还没达到 TOKENICODE 视觉/布局水准。
- **视觉基准**：TOKENICODE 本地截图与代码；Liquid Glass 采用
  Apple 官方 SwiftUI `glassEffect(_:in:)` + `GlassEffectContainer`，
  并保留旧系统 fallback。

## Key Changes

- **原生视觉系统重做**：建立统一 Liquid Glass 组件层，替换默认
  `Form` / `List` / `Button` 拼装感；覆盖 sidebar、toolbar、composer、
  settings modal、popover、cards、search fields、segmented tabs、file rows、
  tool/permission cards。
- **布局对齐 TOKENICODE**：三栏结构、左侧大号 New Chat CTA、
  会话/项目/任务组列表、中心 chat header/transcript/composer、右侧
  Files/Skills inspector；按 TOKENICODE 截图的间距、圆角、层级、
  按钮位置和空态重排。
- **功能补齐**：完成会话 pin/archive/search/running filter/batch、
  undo delete/AI title；文件树 20+ 图标、新建、重命名、删除、搜索、
  dirty guard、HTML preview、native code editor；inline permission、
  plan/question、slash command、rewind、agents、skills、MCP、
  provider presets/test/import/export、CLI install/update/login/repair。
- **烧完 9 个 `PARTIAL`**：重点关闭 `UI-2`、`UI-4`、`RT-2`、
  `RT-3`、`RT-4`、`RT-5`、`RT-7`、`PR-5`、`PR-6`；每项
  只能用行为证据升 `PASS`，不能只靠源码存在或测试变绿。
- **产品文档同步**：`README` / `CHANGELOG` / parity matrix /
  gate status 更新为真实可验收状态；图标、DMG、release metadata
  继续使用 LiquidCode 品牌，但视觉质量要达到 TOKENICODE 级别。

## Test & Acceptance Plan

- **单元/工程**：Xcode test/build、release dry-run、codesign/DMG/lipo
  checks。
- **行为验收**：逐项跑新建项目、发送、停止、权限审批、
  Plan approve/reject、文件编辑保存、HTML preview、rewind、
  provider test、CLI setup/update、MCP/Skills CRUD。
- **视觉验收**：用 TOKENICODE `main-interface`、`streaming-chat`、
  `plan-mode`、`file-explorer`、`file-editing`、`settings`、`skills`、
  `html-preview` 截图逐屏对比 LiquidCode，同 viewport 截图留证。
- **完成门槛**：功能和 TOKENICODE 一样；布局和 TOKENICODE 一样；
  所有按钮都有对应操作；视觉达到 macOS 27 Liquid Glass 水准。
  任一不满足，不算完成。

## Assumptions

- 按你刚确认的方向：保留 LiquidCode app/bundle/DMG 品牌，
  TOKENICODE 作为功能、布局、交互、视觉 parity 参考。
- 不改弱测试、不跳过真实行为证据、不把绿色构建当产品完成。
