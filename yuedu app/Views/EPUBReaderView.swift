import SwiftUI
import UIKit

struct EPUBReaderView: UIViewControllerRepresentable {
    @ObservedObject var renderer: EPUBPageRenderer
    var currentPage: Int
    var onTapCenter: () -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer, onTapCenter: onTapCenter)
    }
    
    func makeUIViewController(context: Context) -> EPUBPageViewController {
        let pageVC = context.coordinator.epubCoordinator.pageViewController
        
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleCenterTap))
        tap.cancelsTouchesInView = false
        pageVC.view.addGestureRecognizer(tap)
        
        return pageVC
    }
    
    func updateUIViewController(_ controller: EPUBPageViewController, context: Context) {
        context.coordinator.onTapCenter = onTapCenter
        
        // Sync book data to the controller if totalPages or pageMap changes
        context.coordinator.epubCoordinator.updateBookData()
        
        // Only programmatically jump if our SwiftUI page differs from the displayed one
        let lastPage = context.coordinator.lastPage
        if lastPage != currentPage {
            let isAdjacent = abs(currentPage - lastPage) == 1
            context.coordinator.epubCoordinator.jumpToPage(currentPage, animated: isAdjacent)
            context.coordinator.lastPage = currentPage
        }
    }
    
    final class Coordinator: NSObject {
        let epubCoordinator: EPUBPageCoordinator
        var lastPage: Int
        var onTapCenter: () -> Void
        
        @MainActor
        init(renderer: EPUBPageRenderer, onTapCenter: @escaping () -> Void) {
            self.epubCoordinator = EPUBPageCoordinator(renderer: renderer)
            self.lastPage = renderer.currentEpubPage
            self.onTapCenter = onTapCenter
            super.init()
        }
        
        @objc func handleCenterTap() {
            onTapCenter()
        }
    }
}
