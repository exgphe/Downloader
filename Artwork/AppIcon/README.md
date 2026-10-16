# Downloader App Icon

简洁的下载箭头和接收托盘，蓝色背景。所有符号均为自行绘制的实心 SVG 路径，无文字、外部字体或位图纹理。

- iOS / macOS：[`AppIcon.icon`](../../Shared%20%28App%29/AppIcon.icon) 是可直接在 Icon Composer 中编辑的原生文档。箭头与托盘分成两个材质组，背景在文档中定义；深色保持相同几何并使用海军蓝。透明和着色外观由系统生成。
- visionOS：[`AppIcon.solidimagestack`](../../visionOS%20%28App%29/Assets.xcassets/AppIcon.solidimagestack) 使用前层箭头、中层托盘、后层蓝色背景。每层 1024 × 1024；前景透明，背景满幅不透明。PNG 从相同 SVG 母版生成，源图不预先裁成圆形。
- Safari 扩展：工具栏使用同一 SVG 路径的单色下载符号，由 Safari 着色；扩展设置与弹窗使用从原生 `AppIcon.icon` 导出的全彩图标。
- 预览：`Preview.png` 由苹果 `ictool` 原生导出，展示 iOS 默认、深色与着色深色外观。

源图不包含圆角遮罩、高光、阴影、模糊或倒角。Liquid Glass 的材质、高光、透明度和阴影由 Icon Composer 配置与系统渲染；visionOS 的圆形遮罩、浮雕及层间阴影由系统施加。保持主体居中，留有适合三端遮罩的边距。

重新生成 visionOS 图层（需要 librsvg）：

```sh
uv run --no-project Scripts/generate_icon_assets.py
uv run --no-project Scripts/generate_safari_icons.py
```

`AppIcon.icon` 的向量前景母版位于其 `Assets` 子目录，visionOS 背景母版为本目录的 `vision-background.svg`。Xcode 为低于 iOS / macOS 26 的目标系统生成兼容图标，无需另维护小尺寸位图集合。

依据苹果最新 [App icons HIG](https://developer.apple.com/design/human-interface-guidelines/app-icons)（2026-06-08 更新）、[Icon Composer 文档](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer) 与 [Asset Catalog 图标配置](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)。
