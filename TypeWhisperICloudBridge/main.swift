import Foundation

let delegate = PremiumICloudBridgeListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
