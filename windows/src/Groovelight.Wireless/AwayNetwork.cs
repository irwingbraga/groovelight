using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace Groovelight.Wireless;

/// <summary>
/// Reaching the computer away from home: through a private network it and the devices share (Tailscale), never the open
/// internet. A request is from home when it comes from the network of one of the computer's own connections (Wi-Fi,
/// Ethernet); anything else is away: devices pair only at home, and reach it away only when allowed on its device page.
/// </summary>
public static class AwayNetwork
{
    internal sealed record Network(byte[] Address, byte[] Mask)
    {
        public bool Contains(byte[] bytes) => bytes.Length == Address.Length && bytes.Select((value, index) => (value & Mask[index]) == (Address[index] & Mask[index])).All(match => match);
    }

    private static (List<Network> Networks, DateTime At)? cache;
    private static readonly Lock gate = new();

    public static bool IsAway(IPAddress address) => IsAway(address.GetAddressBytes(), LocalNetworks());

    internal static bool IsAway(byte[] bytes, IReadOnlyList<Network> local)
    {
        bytes = Unmapped(bytes);
        if (bytes.SequenceEqual(new byte[] { 127, 0, 0, 1 }) || bytes.SequenceEqual(new byte[15].Append((byte)1))) return false;
        // Link-local addresses never cross a router.
        if (bytes.Length == 4 && bytes[0] == 169 && bytes[1] == 254 || bytes.Length == 16 && bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) return false;
        return !local.Any(network => network.Contains(bytes));
    }

    /// <summary>An IPv4 address seen through IPv6 (<c>::ffff:a.b.c.d</c>) as IPv4.</summary>
    internal static byte[] Unmapped(byte[] bytes) =>
        bytes.Length == 16 && bytes.Take(10).All(value => value == 0) && bytes[10] == 0xFF && bytes[11] == 0xFF ? bytes[12..] : bytes;

    /// <summary>Whether an address is Tailscale's (100.64.0.0/10, or fd7a:115c:a1e0::/48).</summary>
    internal static bool IsTailscale(byte[] bytes) => bytes.Length switch
    {
        4 => bytes[0] == 100 && (bytes[1] & 0xC0) == 64,
        16 => bytes.Take(6).SequenceEqual(new byte[] { 0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0 }),
        _ => false,
    };

    private static IEnumerable<(byte[] Address, byte[] Mask, bool PointToPoint)> Interfaces()
    {
        NetworkInterface[] interfaces;
        try { interfaces = NetworkInterface.GetAllNetworkInterfaces(); }
        catch (NetworkInformationException) { yield break; }
        foreach (var item in interfaces)
        {
            if (item.OperationalStatus != OperationalStatus.Up) continue;
            var pointToPoint = item.NetworkInterfaceType is NetworkInterfaceType.Ppp or NetworkInterfaceType.Tunnel;
            foreach (var unicast in item.GetIPProperties().UnicastAddresses)
            {
                var address = unicast.Address.GetAddressBytes();
                var prefix = unicast.PrefixLength;
                var mask = new byte[address.Length];
                for (var bit = 0; bit < Math.Min(prefix, address.Length * 8); bit++) mask[bit / 8] |= (byte)(0x80 >> (bit % 8));
                yield return (address, mask, pointToPoint);
            }
        }
    }

    /// <summary>The computer's local networks (not point-to-point ones such as Tailscale and VPNs), read again every 10 seconds.</summary>
    internal static List<Network> LocalNetworks()
    {
        lock (gate)
        {
            if (cache is { } cached && DateTime.UtcNow - cached.At < TimeSpan.FromSeconds(10)) return cached.Networks;
            var networks = Interfaces().Where(item => !item.PointToPoint && !IsTailscale(item.Address)).Select(item => new Network(item.Address, item.Mask)).ToList();
            cache = (networks, DateTime.UtcNow);
            return networks;
        }
    }

    /// <summary>This computer's Tailscale addresses (IPv4 first): what paired devices try when it is not on their network.</summary>
    public static List<string> Addresses() => Interfaces().Where(item => IsTailscale(item.Address)).OrderBy(item => item.Address.Length)
        .Select(item => new IPAddress(item.Address).ToString()).Distinct().ToList();
}
