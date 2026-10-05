import receive_sharing_intent

/// Nimmt geteilte Dateien entgegen und öffnet PaperBuddy damit.
class ShareViewController: RSIShareViewController {
  override func shouldAutoRedirect() -> Bool {
    return true
  }
}
