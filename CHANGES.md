# Placard 2.1.2 — 壁纸包导出

基于上游 `v2.0.3` 改的源码树。Xcode 26 打开即用；新增的 `.swift` 会被自动收进 target（工程用的是 `PBXFileSystemSynchronizedRootGroup`，不用手动加文件引用）。

## 加了什么

### 1. 导出已安装壁纸 → `.tendies`

`Library` 标签页里，每张已安装壁纸：

- 左滑 → **Export**
- 长按 → **Export .tendies**
- 右上 **Select** 多选 → 工具栏 **Export**（批量）

导出动作是把 PosterBoard 容器里的描述符目录

```
<PosterBoard 容器>/Library/Application Support/PRBPosterExtensionDataStore/<版本>/Extensions/<provider>/<descriptors|configurations>/<UUID>/
```

复制到临时目录，重排成包内结构 `descriptors/<UUID>/…`，再用 ZIPFoundation 压成 `.tendies`，最后弹系统分享单（可「存储到文件」、AirDrop、发微信）。

打包时剔除 `RuntimeSnapshot-*.atx`、`.DS_Store`、`._*` —— 这些是本机渲染出来的运行时快照，换设备没意义，而且体积大。

### 2. 下载的原包不再随手删

原来 `WallpaperInstaller` 把下载解压写盘后，整个临时工作目录 `defer` 掉，包就没了。现在下载成功后会先存一份到

```
Documents/WallpaperPackages/<壁纸名>-<FNV1a tag>.tendies
```

字节级原样保留（不重新打包）。`Library` 左上角**箱子图标**进去能看、能单条导出、能全部导出、能删。

### 3. 详情页导出

浏览页点开某张壁纸，如果它的原包已经下载过，右上角出现导出按钮。

### 4. 顺手的两处

- `Documents` 目录对「文件」App 可见（`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`），导出的包能直接在 Files 里拖走。
- 版本号 2.0.3 → **2.1.2**，build 1 → 2。

## 改了哪些文件

| 文件 | 改动 |
|---|---|
| `placard/WallpaperExporter.swift` | **新增**：路径、命名、原包仓库、打包器、导出状态机、分享单 |
| `placard/DownloadedPackagesView.swift` | **新增**：已下载包列表 |
| `placard/Exploit/WorseQuery.swift` | 新增 `stageInstalledWallpaper(_:into:)`、`validatedStorage(for:)`、`pruneExportedDescriptor(_:)`，复用原有 `consume` / `storeRoots` |
| `placard/WallpaperInstaller.swift` | 下载完成后 `WallpaperPackageStore.store(...)` 存一份原包 |
| `placard/InstalledWallpapersView.swift` | 导出入口（左滑/长按/多选）、导出进度、分享单、箱子入口 |
| `placard/WallpaperDetailView.swift` | 详情页导出按钮、导出失败提示 |
| `placard/en.lproj/Localizable.strings`、`zh-Hans.lproj/Localizable.strings` | 新文案（中英） |
| `placard.xcodeproj/project.pbxproj` | 版本号、两个 Info.plist key |

完整改动见 `../placard-2.1.0-export.patch.diff`（对上游 `main` 的 unified diff）。

## 实现要点

- **权限链没动**：导出走 `WorseQuery.consume(path:create:false)`，和「列出 / 删除已安装壁纸」完全同一条 sandbox-extension 路径。App 能装壁纸，就一定能导出。
- **路径校验和删除一样严**：`storagePath` 归一化、解析软链后必须正好等于 `Extensions/<provider>/<component>/<uuid>`，且落在已知 store root 下，否则拒。
- **原子写**：先写 `<name>.tendies.part`，重开 `Archive` 验证条目数 > 0，再 `moveItem` 到最终名；中途失败不会留下半个能误指导入的包。
- **重复导出不覆盖**：同名自动加 `-2`、`-3`。
- **导出的是描述符，不是截图**：包内是 CAML 图层 + 帧序列 png（视频类 provider 是 `.mov`），与原包同构，可以再导回 Placard / Pocket Poster。

## 构建

### 云端出包（不用 Mac）

仓库里已经放了 `.github/workflows/build-unsigned.yml`（替换掉上游那个会自动发 Release 的）。推到任何 GitHub 仓库：

```bash
cd placard-2.1.2
git init && git add -A && git commit -m "placard 2.1.2 export"
git branch -M main
git remote add origin git@github.com:<你>/<仓库>.git
git push -u origin main
```

然后 Actions → **Build unsigned IPA** → Run workflow，可填 `bundle_id` / `marketing_version`。
流程：`xcodebuild archive`（`CODE_SIGNING_ALLOWED=NO`）→ `package-ipa.py` 用 ad-hoc 签名并把 `group.$(BUNDLE_ID)` 写进 entitlements → 校验 entitlements 里确实有 App Group → 上传 artifact。约 4–6 分钟，产物 `placard-v2.1.2-unsigned.ipa`。

macOS runner 分钟数：公开仓库免费；私有仓库按 10 倍系数扣（5 分钟 ≈ 50 分钟额度）。

### 本地出包

```bash
open placard.xcodeproj      # Xcode 26+，选自己的 Team
# 真机 iOS 26+ 运行
```

签名时 **必须**在 provisioning profile 里带上至少一个 App Group。`placard.entitlements` 里的 `group.$(PRODUCT_BUNDLE_IDENTIFIER)` 会展开成 `group.me.ssus.placard`；`GestaltAppGroupResolver` 是动态读自己签名里的 app group，名字不必和上游一致，但 profile 里得真有一个。免费个人开发者账号没有 App Groups 能力，跑不起来；付费账号 / 企业签可以。

## 边界

- 导出 `configurations`（My Wallpapers）里的条目时，包内会多几个 PosterBoard 生成的运行时 plist（`com.apple.posterkit.provider.instance.*`）。重新导入没问题，Placard 会重写 descriptor ID；但那份不是「原作者发布的原包」。
- 单包上限仍是 250 MB（`WallpaperInstaller.maximumPackageBytes`）。
- 导出是复制 + 压缩，最大的包（80 MB 级）几秒；期间顶部显示「正在打包…」。
- `.tendiex` 不归这个功能管，它是加密格式，转换仍用 `tendiex2tendies.py`。

## 上游更新壁纸之后

**新壁纸自动可用，不用重新编译 App，也不用动导出代码。**

- 目录（`wallpapers.json` 等）是运行时拉的，`WallpaperCatalog` 有持久缓存、成功请求后整体替换；App 冷启动或下拉刷新就能看到新条目。
- 新条目走同一条 `WallpaperInstaller.install(_:)`，下载完成即落一份到 `Documents/WallpaperPackages/`，所以「已下载的包」列表和详情页导出按钮同样对它生效。
- 已安装壁纸的导出完全不碰目录：读的是 PosterBoard 容器里的描述符，跟这张壁纸谁做的、什么时候上架无关。上游删了条目，你已装的那份照样能导出。

两个已知边界：

1. **同一 URL 换了内容**（上游重发同名文件）。2.1.1 起每次安装都会覆盖旧副本；之前是「文件存在就跳过」，会留旧字节。
2. **iOS 改了 PosterBoard 存储布局**（比如 27.x 换了 `PRBPosterExtensionDataStore` 的路径或目录名）。这跟壁纸更新无关，属于系统升级适配，`WorseQuery.storeRoots` 要跟着改。

## 自签时唯一必须对上的一点

云编译出来的包是 ad-hoc 签名，entitlements 里带 `com.apple.security.application-groups = [group.<bundle id>]`。
你用证书重签（zsign / ESign / Sideloadly 都一样）时，**证书对应的 provisioning profile 里必须真的包含一个 App Group**，否则重签会把这个 entitlement 摘掉，`worse_query` 直接返回 -1（`No usable App Group was found`），装壁纸和导出都会失败。

免费个人开发者账号没有 App Groups 能力，走不通。付费账号：在 developer 后台建一个 App Group（例如 `group.me.ssus.placard`），把 App ID 的 App Groups 勾上，重新生成 profile。
`GestaltAppGroupResolver` 是运行时读自己签名里的 app group，所以名字不必和上游一致——只要 profile 里有一个、且重签时保留下来了就行。
