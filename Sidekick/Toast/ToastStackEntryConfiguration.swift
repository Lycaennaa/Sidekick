import CoreGraphics

struct ToastStackEntryConfiguration: Equatable {
    let maximumSize: CGSize
    let layoutPriority: Int
    let preservesRecoverableToast: Bool
}
