import SwiftUI
import UIKit

/// A document can arrive while any tab, sheet, or reader is visible. Attach to
/// this scene's actual window and present above its current controller, rather
/// than asking an already occupied root SwiftUI sheet to present another one.
struct ImportedBookPresentation: UIViewControllerRepresentable {
    let request: SharedImportQueueDrainer.ReaderRequest?
    let store: BookStore
    let subscriptionStore: SubscriptionStore
    let didPresent: (UUID) -> Void
    var customizationRequest: SharedCustomizationDocument? = nil
    var didPresentCustomization: (UUID) -> Void = { _ in }
    /// Reads a shared customization file into an import plan. `ContentView` routes it
    /// through the drainer so the 匯入中 indicator is up while it runs.
    var readCustomization: (SharedCustomizationDocument) async throws -> SharedCustomizationImportService.Plan = {
        try await SharedCustomizationImportService.load($0)
    }

    func makeUIViewController(context: Context) -> ImportedBookPresentationController {
        ImportedBookPresentationController()
    }

    func updateUIViewController(_ controller: ImportedBookPresentationController, context: Context) {
        if let customizationRequest {
            let read = readCustomization
            controller.receive(requestID: customizationRequest.id, makeFlow: { window, finish in
                SharedCustomizationImportFlow(
                    document: customizationRequest,
                    window: window,
                    read: read,
                    finish: finish
                )
            }, didStart: didPresentCustomization)
            return
        }
        controller.receive(requestID: request?.id, makeDestination: { scene in
            guard let request else { return nil }
            return UIHostingController(rootView:
                BookReaderView(bookId: request.bookID)
                    .id(request.bookID)
                    .environmentObject(store)
                    .environmentObject(subscriptionStore)
                    .environment(\.appDependencies, .live)
                    .followsScenePhase(of: scene)
            )
        }, didPresent: didPresent)
    }
}

@MainActor
final class ImportedBookPresentationController: UIViewController {
    /// What a request turns into once the window can show it: a full-screen destination
    /// (a book), or a flow of its own presentations (a shared customization file, which
    /// asks with an alert and reports in a sheet).
    private enum Work {
        case destination((UIWindowScene) -> UIViewController?)
        case flow((UIWindow, @escaping () -> Void) -> SharedCustomizationImportFlow)
    }

    private var pendingID: UUID?
    private var presentingID: UUID?
    private var pendingWork: Work?
    private var didPresent: ((UUID) -> Void)?
    private var waitingForTransition = false
    /// The customization flow on screen. Held here so it outlives its own alerts, and
    /// so a second document waits for it instead of presenting over its alert.
    private var activeFlow: SharedCustomizationImportFlow?
    private weak var presentationWindow: UIWindow?

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentPending()
    }

    func receive(requestID: UUID?, makeDestination: @escaping (UIWindowScene) -> UIViewController?,
                 didPresent: @escaping (UUID) -> Void) {
        pendingID = requestID
        pendingWork = .destination(makeDestination)
        self.didPresent = didPresent
        presentPending()
    }

    /// A shared customization file. `didStart` acknowledges the request as soon as its
    /// flow begins; the flow then owns every presentation until it calls `finish`.
    func receive(
        requestID: UUID,
        makeFlow: @escaping (UIWindow, _ finish: @escaping () -> Void) -> SharedCustomizationImportFlow,
        didStart: @escaping (UUID) -> Void
    ) {
        pendingID = requestID
        pendingWork = .flow(makeFlow)
        didPresent = didStart
        presentPending()
    }

    func presentPending() {
        // Full-screen readers remove the underlying scene view from the window.
        // Keep this scene's window while it is attached so subsequent Open In
        // events can still reach the controller currently presented above it.
        if let window = viewIfLoaded?.window { presentationWindow = window }
        guard !waitingForTransition, presentingID == nil, activeFlow == nil,
              let requestID = pendingID, let work = pendingWork,
              let window = presentationWindow, !window.isHidden,
              var presenter = window.rootViewController else { return }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        // Open In can arrive during a sheet's dismissal or scene activation.
        // Wait for UIKit's real transition completion, never a timed retry.
        if let transition = presenter.transitionCoordinator {
            waitingForTransition = true
            let scheduled = transition.animate(alongsideTransition: nil) { [weak self] _ in
                self?.waitingForTransition = false
                self?.presentPending()
            }
            if scheduled { return }
            waitingForTransition = false
        }
        let acknowledge = didPresent
        switch work {
        case .flow(let makeFlow):
            let flow = makeFlow(window) { [weak self] in
                self?.activeFlow = nil
                self?.presentPending()
            }
            activeFlow = flow
            // Acknowledged now, with the pending ID cleared in the same step, so a
            // re-render still carrying this request cannot start the file twice.
            if pendingID == requestID { pendingID = nil }
            acknowledge?(requestID)
            flow.start()
        case .destination(let makeDestination):
            guard let scene = window.windowScene, let destination = makeDestination(scene) else { return }
            presentingID = requestID
            destination.modalPresentationStyle = .fullScreen
            presenter.present(destination, animated: true) { [weak self] in
                guard let self else { return }
                self.presentingID = nil
                if self.pendingID == requestID { self.pendingID = nil }
                acknowledge?(requestID)
                self.presentPending()
            }
        }
    }
}

#Preview {
    ImportedBookPresentation(request: nil, store: BookStore(),
                             subscriptionStore: .shared, didPresent: { _ in })
}
