using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace Groovelight.Wireless;

/// <summary>
/// The computer's identity for HTTPS on the local network (protocol v2): a P-256 key and a self-signed certificate, made
/// once and kept in the data folder (the key encrypted for this Windows user). Devices do not check it against any
/// authority: they pin its fingerprint after the computer proves, with the pairing key, that it is the one serving it.
/// </summary>
public static class TlsIdentity
{
    /// <summary>The identity in <paramref name="file"/>, made now if there is none. Returns it with its fingerprint (SHA-256 of the DER, hex).</summary>
    public static (X509Certificate2 Certificate, string Fingerprint) Load(string file)
    {
        if (File.Exists(file))
        {
            try
            {
                var certificate = X509CertificateLoader.LoadPkcs12(Unprotect(File.ReadAllBytes(file)), null, X509KeyStorageFlags.Exportable);
                if (certificate.HasPrivateKey) return (certificate, Fingerprint(certificate));
            }
            catch (CryptographicException) { }
        }
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=Groovelight", key, HashAlgorithmName.SHA256);
        var now = DateTimeOffset.UtcNow;
        using var made = request.CreateSelfSigned(now.AddDays(-1), now.AddYears(30));
        // Imported again from its PKCS #12: a certificate made in memory cannot serve TLS on Windows.
        var pfx = made.Export(X509ContentType.Pkcs12);
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllBytes(file, Protect(pfx));
        var loaded = X509CertificateLoader.LoadPkcs12(pfx, null, X509KeyStorageFlags.Exportable);
        return (loaded, Fingerprint(loaded));
    }

    public static string Fingerprint(X509Certificate2 certificate) => Convert.ToHexStringLower(SHA256.HashData(certificate.RawData));

    private static byte[] Protect(byte[] data) => OperatingSystem.IsWindows() ? ProtectedData.Protect(data, null, DataProtectionScope.CurrentUser) : data;

    private static byte[] Unprotect(byte[] data) => OperatingSystem.IsWindows() ? ProtectedData.Unprotect(data, null, DataProtectionScope.CurrentUser) : data;
}
