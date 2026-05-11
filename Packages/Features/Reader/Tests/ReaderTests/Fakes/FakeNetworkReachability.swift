import Domain

actor FakeNetworkReachability: NetworkReachability {
    var online: Bool

    init(online: Bool) {
        self.online = online
    }

    func isOnline() -> Bool {
        online
    }

    func setOnline(_ value: Bool) {
        online = value
    }
}
