using System.Numerics;
using System.Security.Cryptography;

namespace Groovelight.Wireless;

/// <summary>
/// X25519 key agreement (RFC 7748), as CryptoKit's <c>Curve25519.KeyAgreement</c> on the Mac and the phones: raw
/// 32-byte keys. Managed, since .NET has no portable X25519; it runs once per pairing, so speed does not matter.
/// </summary>
public static class X25519
{
    private static readonly BigInteger P = BigInteger.Pow(2, 255) - 19;
    private static readonly BigInteger A24 = 121665;

    public static byte[] NewPrivateKey() => RandomNumberGenerator.GetBytes(32);

    /// <summary>The public key of a private one (the scalar times the base point 9).</summary>
    public static byte[] PublicKey(byte[] privateKey)
    {
        var basePoint = new byte[32];
        basePoint[0] = 9;
        return Multiply(privateKey, basePoint);
    }

    /// <summary>The shared secret; throws when it is all zeros (a low-order point), as CryptoKit does.</summary>
    public static byte[] SharedSecret(byte[] privateKey, byte[] peerPublicKey)
    {
        if (peerPublicKey.Length != 32) throw new CryptographicException("A public key is 32 bytes.");
        var secret = Multiply(privateKey, peerPublicKey);
        if (secret.All(value => value == 0)) throw new CryptographicException("Not a valid public key.");
        return secret;
    }

    private static byte[] Multiply(byte[] scalar, byte[] point)
    {
        if (scalar.Length != 32) throw new CryptographicException("A private key is 32 bytes.");
        var k = (byte[])scalar.Clone();
        k[0] &= 248;
        k[31] &= 127;
        k[31] |= 64;
        var u = (byte[])point.Clone();
        u[31] &= 127;
        var x1 = new BigInteger(u, isUnsigned: true, isBigEndian: false);
        BigInteger x2 = 1, z2 = 0, x3 = x1, z3 = 1;
        var swap = 0;
        var kn = new BigInteger(k, isUnsigned: true, isBigEndian: false);
        for (var t = 254; t >= 0; t--)
        {
            var bit = (int)((kn >> t) & 1);
            swap ^= bit;
            if (swap == 1)
            {
                (x2, x3) = (x3, x2);
                (z2, z3) = (z3, z2);
            }
            swap = bit;
            var a = Mod(x2 + z2);
            var aa = Mod(a * a);
            var b = Mod(x2 - z2);
            var bb = Mod(b * b);
            var e = Mod(aa - bb);
            var c = Mod(x3 + z3);
            var d = Mod(x3 - z3);
            var da = Mod(d * a);
            var cb = Mod(c * b);
            x3 = Mod((da + cb) * (da + cb));
            z3 = Mod(x1 * Mod((da - cb) * (da - cb)));
            x2 = Mod(aa * bb);
            z2 = Mod(e * (aa + A24 * e));
        }
        if (swap == 1)
        {
            (x2, x3) = (x3, x2);
            (z2, z3) = (z3, z2);
        }
        var result = Mod(x2 * BigInteger.ModPow(z2, P - 2, P));
        var bytes = result.ToByteArray(isUnsigned: true, isBigEndian: false);
        var output = new byte[32];
        Array.Copy(bytes, output, Math.Min(bytes.Length, 32));
        return output;
    }

    private static BigInteger Mod(BigInteger value)
    {
        var result = value % P;
        return result.Sign < 0 ? result + P : result;
    }
}
