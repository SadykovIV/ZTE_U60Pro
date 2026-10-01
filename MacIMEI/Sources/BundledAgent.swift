import Foundation

/// Exact agent shipped by automatic setup, the agent installer and VPN updates.
/// Resource refresh must update these pins before packaging.
enum BundledAgent {
    static let version = "2.7.0-esim.8"
    static let sha256 = "8ee8073b684613f358a5b857f7ed85ac165fc96f0d74980b04be006659ebea67"
    static let dashboardInstallerSHA256 = "9f34db82ead9c636d49673ef0c24793124a2a59b3c0323a11b8e56d4d9a6d44f"
    // Exact released hashes previously allowed by the signed update helper.
    // Keep this host check independent of shell source formatting.
    static let supportedUpgradeHashes: Set<String> = [sha256,
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
        case "c50ba6b7ac6f77c581c2b657ba769f976d8d20aca0c6b7d08c9254ef2de9d346": return "2.8.0 · предыдущий публичный агент"
        case "6168ae6c539bb3ca7136eb40a1d4cae03d75aa18900be105f2ff2d5016da4b5c": return "2.7.0-esim.7 · eSIM, VPN, дисплей, RU/EN и TTL"
        case "be945c0a7181070aa69be3bb579a1e967a1cf147b2af2987f31ae5d242b10a66": return "2.7.0-esim.6 · eSIM, VPN, дисплей, RU/EN и TTL"
        case sha256: return version + " · eSIM, VPN, дисплей, RU/EN и TTL"
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
