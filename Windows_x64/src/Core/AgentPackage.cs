using System.Security.Cryptography;
using System.Collections.Frozen;

namespace ZteImeiStudio.Windows.Core;

/// <summary>The same pinned build is installed permanently and used by private desktop RPC.</summary>
public static class AgentPackage
{
    public const string Version = "2.9.0-esim.3";
    public const string Sha256 = "b23d57c223e898df9d26574fdfbd01a0b6f4d3835ebe9752ed642b0484625ef7";
    // Verified app 1.24.3 build 38 and its preserved source/artifact receipt.
    public const string LegacyCardCheckSha256 = "413ba4b0a07540d6901e87e74c9730196eb3373cf35b8914e31a8194bfe5a839";
    public const string LegacyPublicSha256 = "c50ba6b7ac6f77c581c2b657ba769f976d8d20aca0c6b7d08c9254ef2de9d346";
    public const string LegacyVpnSha256 = "3da0915669ca101fe8b2faef3d683405957a2fbd49000a58257d28868321b3df";
    public const string LegacyEsimSha256 = "7a2d1a517d564a3d66dfe98e6622be6ca2428635aa9cbd83cbf02c179dd7703e";
    public const string LegacyEsimWebSha256 = "7cdddfbf529a0de70726cafbfacbd56d77286b001feb1efcf123ef323b07d433";
    public const string LegacyEsimTraceSha256 = "52324f0c99f13a3445c08431f8b4ed15b468352f5b20709e3304cf4d32577b48";
    public const string LegacyEsimRootsSha256 = "66c3fb83f3db5b194a39db563a453d421f6a4f3ccb9228cf360883ce2fed1629";
    public const string LegacyEsimRadioSha256 = "be945c0a7181070aa69be3bb579a1e967a1cf147b2af2987f31ae5d242b10a66";
    public const string LegacyEsimPagesSha256 = "6168ae6c539bb3ca7136eb40a1d4cae03d75aa18900be105f2ff2d5016da4b5c";
    // Preserved 2.7.0-esim.8 binary and release manifest; never learned from a device.
    public const string LegacyLocalEsimRecoverySha256 = "e9f3e2170a7a2fa80a4836fd7d0db92c4aa119b4b8cceaa0907450123de29d19";
    public static string? VersionForHash(string hash) => hash == Sha256 ? Version : hash switch
    {
        "8ee8073b684613f358a5b857f7ed85ac165fc96f0d74980b04be006659ebea67" => "2.7.0-esim.8",
        LegacyLocalEsimRecoverySha256 => "2.7.0-esim.8",
        LegacyCardCheckSha256 => "2.9.0-esim.2",
        LegacyPublicSha256 => "2.8.0",
        LegacyVpnSha256 => "2.7.0-vpn.1",
        LegacyEsimSha256 => "2.7.0-esim.1",
        LegacyEsimWebSha256 => "2.7.0-esim.2",
        LegacyEsimTraceSha256 => "2.7.0-esim.3",
        LegacyEsimRootsSha256 => "2.7.0-esim.4",
        LegacyEsimRadioSha256 => "2.7.0-esim.6",
        LegacyEsimPagesSha256 => "2.7.0-esim.7",
        _ => null
    };
    public static readonly IReadOnlySet<string> SupportedUpgradeHashes = new[] {
        Sha256,
        "0563f12c64311bf1058cd3a4136a0b328d07e1cba7b8e92b962ec5bf3c7e4215",
        "07154bffefb022eff87c46deb51b73501110edd6e6bf9248ccbec248b2fbe56e",
        "3da0915669ca101fe8b2faef3d683405957a2fbd49000a58257d28868321b3df",
        "413ba4b0a07540d6901e87e74c9730196eb3373cf35b8914e31a8194bfe5a839",
        "4d28622aa277c5407b142dea7f3c919c992b8beda9ec622a889a02bd7ab721eb",
        "52324f0c99f13a3445c08431f8b4ed15b468352f5b20709e3304cf4d32577b48",
        "5deb5e93ee7d37403b0a931f0e127c64e4d9b4825855653e5b890572b02848aa",
        "6168ae6c539bb3ca7136eb40a1d4cae03d75aa18900be105f2ff2d5016da4b5c",
        "66c3fb83f3db5b194a39db563a453d421f6a4f3ccb9228cf360883ce2fed1629",
        "7a2d1a517d564a3d66dfe98e6622be6ca2428635aa9cbd83cbf02c179dd7703e",
        "7cdddfbf529a0de70726cafbfacbd56d77286b001feb1efcf123ef323b07d433",
        "8d72032d37fff80195a106b257cc1f72ec76a4085224b0161a4bc81cd0167a4e",
        "8ee8073b684613f358a5b857f7ed85ac165fc96f0d74980b04be006659ebea67",
        "b082c8dfc8238d73dc0bdee7453cd60e0816f7f16b2febbf42d16ac7b6bfd466",
        "b5c27d398e85db8a87d454d729cb36f22e54a2d832fb1117b27aa055e5032537",
        "be945c0a7181070aa69be3bb579a1e967a1cf147b2af2987f31ae5d242b10a66",
        "c50ba6b7ac6f77c581c2b657ba769f976d8d20aca0c6b7d08c9254ef2de9d346",
        "c7fd7f594db16c71f67ba066d112fefabca4290f74cc3f2506350260479a19f6",
        "d3fd8a8316eb1f63d6e737ef99f8cf7e3a2946cf80acb8df6c3d8bd16911bce4",
        "e138c8eca5612c02e8b40e2af53eb6bfb65f138b0992f2f5dca4a02cc4cac762",
        "e9f3e2170a7a2fa80a4836fd7d0db92c4aa119b4b8cceaa0907450123de29d19",
        "ec4c21f70c666d28b016445eb9ab391e05d21b0974d3c6553671aa73acd183da",
        "f2e0404c2c1be4c058c27b0a19c99c1d380e1c91d61503661424d53e799e235b",
        "f85bd358b6d2b8d418375d45b52472f13e5a25942ed670d6671c275c33204d68",
    }.ToFrozenSet(StringComparer.Ordinal);
    public static bool SupportsVpn(string hash) => VersionForHash(hash) is not null;
    public static void VerifyPayload(byte[] bytes)
    {
        if (bytes.Length is < 64 or > 64 * 1024 * 1024 ||
            !bytes.AsSpan(0,6).SequenceEqual(new byte[] {0x7f,0x45,0x4c,0x46,2,1}) ||
            bytes[18] != 0xb7 || bytes[19] != 0 ||
            Convert.ToHexStringLower(SHA256.HashData(bytes)) != Sha256)
            throw new InvalidDataException("Встроенный агент eSIM повреждён или относится к другой сборке.");
    }
}
