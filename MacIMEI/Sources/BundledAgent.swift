import Foundation

/// Exact agent shipped by automatic setup, the agent installer and VPN updates.
/// Resource refresh must update these pins before packaging.
enum BundledAgent {
    static let version = "2.9.0-esim.12"
    static let sha256 = "1a691eeaa1b34859d934802135feb9b0310c65e03836a69228df2c91f296747a"
    static let dashboardInstallerSHA256 = "5c878b837ad228d7c53b888b42b73ef333aaf8834d11b5e028482b3fa15cc623"
    // Exact released hashes verified against release records and the update path.
    // Keep this host check independent of shell source formatting.
    static let supportedUpgradeHashes: Set<String> = [sha256,
        "a01ac1968f3cbbefcddabd1e3dfa5d5f90e05566df20843c92eca1d3e8fc6ef7",
        "58343b20c918d6a329b60a73e9f2328803ce44008a949799b645a2f95108c20c",
        "8f17bc22c09e2e5315b61a583cf8a6cd8b6ecfda42009c395a6db57b1ab6b12a",
        "ce21d487745511e303b8bdcd9e8703c2e8146514547e9ee8b8a852df19056c90",
        "fce918180873c2c96e573bc395059316f3bf2a4733fe798ed93d9fad96c615a1",
        "59af7b0b45ff2f0d280b6998fb573bd88f2b0d9c28017d8e6f2860b6c29bcbbd",
        "0ab7839ccd1b5930d8dcc74665f1ccfc30d0ad74746f73130760da66343c6659",
        "e258b90032b3b3cb2af7e434f4c2cb83e01777aaf08f0d9b2e3c0c73bbd42ca6",
        "761da4414bce173edd98712d87470069a32d70c53680da61b5a30e26fa7bd012",
        "076824a90eec46702744ae0f383872841d3c4704216ae32de4725f906f86a550",
        "43ecb851c163a0575cdcb0e21561ae5097bb52026daac33cb46c85deba6a278d",
        "9def1ae625eeee2d3357c5583b441c3a910ef546513d10c80355536b3b5146e7",
        "b23d57c223e898df9d26574fdfbd01a0b6f4d3835ebe9752ed642b0484625ef7",
        "f85bd358b6d2b8d418375d45b52472f13e5a25942ed670d6671c275c33204d68",
        "413ba4b0a07540d6901e87e74c9730196eb3373cf35b8914e31a8194bfe5a839", // 1.24.3 build 38; preserved source and artifact receipt
        "e9f3e2170a7a2fa80a4836fd7d0db92c4aa119b4b8cceaa0907450123de29d19", // Frozen 2.7.0-esim.8 release + SHA256/build receipt
        "8ee8073b684613f358a5b857f7ed85ac165fc96f0d74980b04be006659ebea67",
        "c50ba6b7ac6f77c581c2b657ba769f976d8d20aca0c6b7d08c9254ef2de9d346", // Public 2.8.0 / app 1.20.0
        "6168ae6c539bb3ca7136eb40a1d4cae03d75aa18900be105f2ff2d5016da4b5c",
        "be945c0a7181070aa69be3bb579a1e967a1cf147b2af2987f31ae5d242b10a66",
        "66c3fb83f3db5b194a39db563a453d421f6a4f3ccb9228cf360883ce2fed1629",
        "0563f12c64311bf1058cd3a4136a0b328d07e1cba7b8e92b962ec5bf3c7e4215",
        "07154bffefb022eff87c46deb51b73501110edd6e6bf9248ccbec248b2fbe56e",
        "3da0915669ca101fe8b2faef3d683405957a2fbd49000a58257d28868321b3df",
        "4d28622aa277c5407b142dea7f3c919c992b8beda9ec622a889a02bd7ab721eb",
        "52324f0c99f13a3445c08431f8b4ed15b468352f5b20709e3304cf4d32577b48",
        "5deb5e93ee7d37403b0a931f0e127c64e4d9b4825855653e5b890572b02848aa",
        "7a2d1a517d564a3d66dfe98e6622be6ca2428635aa9cbd83cbf02c179dd7703e",
        "7cdddfbf529a0de70726cafbfacbd56d77286b001feb1efcf123ef323b07d433",
        "8d72032d37fff80195a106b257cc1f72ec76a4085224b0161a4bc81cd0167a4e",
        "b082c8dfc8238d73dc0bdee7453cd60e0816f7f16b2febbf42d16ac7b6bfd466",
        "b5c27d398e85db8a87d454d729cb36f22e54a2d832fb1117b27aa055e5032537",
        "c7fd7f594db16c71f67ba066d112fefabca4290f74cc3f2506350260479a19f6",
        "d3fd8a8316eb1f63d6e737ef99f8cf7e3a2946cf80acb8df6c3d8bd16911bce4",
        "e138c8eca5612c02e8b40e2af53eb6bfb65f138b0992f2f5dca4a02cc4cac762",
        "ec4c21f70c666d28b016445eb9ab391e05d21b0974d3c6553671aa73acd183da",
        "f2e0404c2c1be4c058c27b0a19c99c1d380e1c91d61503661424d53e799e235b"
    ]
    static func description(for hash: String) -> String {
        switch hash {
        case "0ab7839ccd1b5930d8dcc74665f1ccfc30d0ad74746f73130760da66343c6659": return "2.9.0-esim.9 · предыдущий агент"
        case "e258b90032b3b3cb2af7e434f4c2cb83e01777aaf08f0d9b2e3c0c73bbd42ca6": return "2.9.0-esim.8 · предыдущий агент"
        case "761da4414bce173edd98712d87470069a32d70c53680da61b5a30e26fa7bd012": return "2.9.0-esim.7 · предыдущий агент"
        case "076824a90eec46702744ae0f383872841d3c4704216ae32de4725f906f86a550": return "2.9.0-esim.6 · требуется обновление для новых компонентов VPN и TTL"
        case "43ecb851c163a0575cdcb0e21561ae5097bb52026daac33cb46c85deba6a278d": return "2.9.0-esim.5 · предыдущий агент"
        case "413ba4b0a07540d6901e87e74c9730196eb3373cf35b8914e31a8194bfe5a839": return "2.9.0-esim.2 · предыдущий агент"
        case "c50ba6b7ac6f77c581c2b657ba769f976d8d20aca0c6b7d08c9254ef2de9d346": return "2.8.0 · предыдущий публичный агент"
        case "6168ae6c539bb3ca7136eb40a1d4cae03d75aa18900be105f2ff2d5016da4b5c": return "2.7.0-esim.7 · eSIM, VPN, дисплей, RU/EN и TTL"
        case "be945c0a7181070aa69be3bb579a1e967a1cf147b2af2987f31ae5d242b10a66": return "2.7.0-esim.6 · eSIM, VPN, дисплей, RU/EN и TTL"
        case "e9f3e2170a7a2fa80a4836fd7d0db92c4aa119b4b8cceaa0907450123de29d19", "8ee8073b684613f358a5b857f7ed85ac165fc96f0d74980b04be006659ebea67": return "2.7.0-esim.8 · предыдущий агент"
        case sha256: return version + " · режим зависит от проверенных возможностей устройства"
        case "66c3fb83f3db5b194a39db563a453d421f6a4f3ccb9228cf360883ce2fed1629": return "2.7.0-esim.4 · eSIM, VPN, дисплей, RU/EN и TTL"
        case "52324f0c99f13a3445c08431f8b4ed15b468352f5b20709e3304cf4d32577b48": return "2.7.0-esim.3 · eSIM, VPN, дисплей, RU/EN и TTL"
        case "7cdddfbf529a0de70726cafbfacbd56d77286b001feb1efcf123ef323b07d433": return "2.7.0-esim.2 · eSIM, VPN, дисплей, RU/EN и TTL"
        case "7a2d1a517d564a3d66dfe98e6622be6ca2428635aa9cbd83cbf02c179dd7703e": return "2.7.0-esim.1 · eSIM, VPN, дисплей, RU/EN и TTL"
        case "3da0915669ca101fe8b2faef3d683405957a2fbd49000a58257d28868321b3df": return "2.7.0-vpn.1 · VPN, дисплей, RU/EN и TTL"
        case "b5c27d398e85db8a87d454d729cb36f22e54a2d832fb1117b27aa055e5032537": return "2.4.1 · RU/EN и TTL"
        case "5deb5e93ee7d37403b0a931f0e127c64e4d9b4825855653e5b890572b02848aa": return "2.4.0"
        case "", "absent": return "Не установлен"
        default: return "Другая сборка / свой агент"
        }
    }
}
