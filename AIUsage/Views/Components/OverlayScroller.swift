import SwiftUI
import AppKit

/// 把外层 SwiftUI `ScrollView` 底下的 `NSScrollView` 固定成**浮层滚动条**（细、半透明、滚动时才淡入）。
///
/// 起因：macOS 的滚动条样式由系统偏好「显示滚动条」决定，默认那档是「根据输入设备自动」——
/// 最近一次输入来自触控板就用浮层样式，来自鼠标就切成老式样式（粗、带槽、常驻不退）。
/// 插着鼠标、或像这台机器一样被远程控制注入鼠标事件时，整个 app 都会顶着那根老式滚动条。
/// 这是个整页仪表盘，常驻的粗滚动条比内容还抢眼，而它承载的信息（页面有多长）在这里也几乎用不上。
///
/// 为什么不能一次全局设置：`NSScroller.preferredScrollerStyle` 在 SDK 里是
/// **只读的类属性**（`@property (class, readonly)`），它反映系统偏好，AppKit 没给写入入口。
/// 能写的只有每个 `NSScrollView.scrollerStyle`，SwiftUI 又没暴露它 ——
/// 所以顺着一层 `NSViewRepresentable` 往上找到承载这个 `ScrollView` 的那个 NSScrollView
/// （往上遇到的**第一个**，不会误伤别的滚动视图），单独给它设。
///
/// 而且写一次不够：AppKit 在偏好变化时会向所有 NSScrollView 广播 `setScrollerStyle:`，
/// 启动后那一下「识别到鼠标、切成老式」正是这么发出来的 —— 实测把样式设成浮层后约两秒
/// 就被这条广播改回老式。所以要订阅 `NSPreferredScrollerStyleDidChangeNotification` 一直维持。
///
/// 只在用户没显式指定过滚动条样式时才动手：真在系统设置里选了「始终显示 / 始终隐藏」
/// 多半是无障碍需求，app 不该覆盖。
struct OverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // 同步调用时这层还没进视图树、更没挂到 NSScrollView 上，得等这一轮布局结束
        DispatchQueue.main.async { adopt(from: probe) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { adopt(from: nsView) }
    }

    private func adopt(from view: NSView) {
        var candidate: NSView? = view
        while let current = candidate {
            if let scrollView = current as? NSScrollView {
                OverlayScrollerKeeper.adopt(scrollView)
                return
            }
            candidate = current.superview
        }
    }
}

/// 维持浮层滚动条的登记处 —— 只为「设过的滚动视图别被系统广播改回去」而存在。
private enum OverlayScrollerKeeper {
    private final class Box {
        weak var view: NSScrollView?
        init(_ view: NSScrollView) { self.view = view }
    }

    private static var boxes: [Box] = []
    private static var observing = false

    /// 用户在系统设置里显式选过滚动条样式就照办，不掺和
    private static var shouldAdapt: Bool {
        UserDefaults.standard.string(forKey: "AppleShowScrollBars") == nil
    }

    static func adopt(_ scrollView: NSScrollView) {
        boxes.removeAll { $0.view == nil }
        if !boxes.contains(where: { $0.view === scrollView }) {
            boxes.append(Box(scrollView))
        }
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { _ in enforce() }
        }
        enforce()
        // 属性写下去这一轮读回来可能还是旧值，AppKit 要到下一次铺排才真正换掉滚动条，再核一遍
        DispatchQueue.main.async(execute: enforce)
    }

    private static func enforce() {
        guard shouldAdapt else { return }
        boxes.removeAll { $0.view == nil }
        for box in boxes {
            guard let view = box.view, view.scrollerStyle != .overlay else { continue }
            view.scrollerStyle = .overlay
        }
    }
}

extension View {
    /// 让这个滚动视图用浮层滚动条。挂在 `ScrollView` **里面**的内容上 ——
    /// 挂在外面的话，`NSViewRepresentable` 会落在 `ScrollView` 之外，往上找就找不到它。
    func overlayScroller() -> some View {
        background(OverlayScroller().frame(width: 0, height: 0))
    }
}
