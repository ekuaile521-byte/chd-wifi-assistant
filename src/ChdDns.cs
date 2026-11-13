using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

// Minimal DNS A-record query. The socket is bound to the campus Wi-Fi address.
public static class ChdDns
{
    public static string[] Query(string host, string localAddress, string serverAddress)
    {
        IPAddress local = IPAddress.Parse(localAddress);
        IPAddress server = IPAddress.Parse(serverAddress);
        if (local.AddressFamily != AddressFamily.InterNetwork || server.AddressFamily != AddressFamily.InterNetwork)
            throw new ArgumentException("Only IPv4 DNS is supported.");
        byte[] randomId = new byte[2];
        using (RandomNumberGenerator random = RandomNumberGenerator.Create()) random.GetBytes(randomId);
        ushort id = (ushort)((randomId[0] << 8) | randomId[1]);
        byte[] query = CreateQuery(host, id);
        using (UdpClient client = new UdpClient(AddressFamily.InterNetwork))
        {
            client.Client.ReceiveTimeout = 2500;
            client.Client.SendTimeout = 2500;
            client.Client.Bind(new IPEndPoint(local, 0));
            client.Connect(new IPEndPoint(server, 53));
            client.Send(query, query.Length);
            IPEndPoint responseFrom = null;
            byte[] response = client.Receive(ref responseFrom);
            return ParseAddresses(response, id);
        }
    }

    private static byte[] CreateQuery(string host, ushort id)
    {
        if (String.IsNullOrWhiteSpace(host) || host.Length > 253) throw new ArgumentException("Invalid hostname.");
        using (MemoryStream bytes = new MemoryStream())
        {
            byte[] header = { (byte)(id >> 8), (byte)id, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
            bytes.Write(header, 0, header.Length);
            foreach (string label in host.TrimEnd('.').Split('.'))
            {
                if (label.Length == 0 || label.Length > 63) throw new ArgumentException("Invalid DNS label.");
                foreach (char c in label)
                    if (!(Char.IsLetterOrDigit(c) || c == '-') || c > 127) throw new ArgumentException("Invalid DNS label.");
                byte[] encoded = Encoding.ASCII.GetBytes(label);
                bytes.WriteByte((byte)encoded.Length);
                bytes.Write(encoded, 0, encoded.Length);
            }
            bytes.WriteByte(0);
            bytes.Write(new byte[] { 0, 1, 0, 1 }, 0, 4);
            return bytes.ToArray();
        }
    }

    private static ushort ReadUInt16(byte[] data, int offset)
    {
        if (offset < 0 || offset + 2 > data.Length) throw new InvalidDataException("Truncated DNS response.");
        return (ushort)((data[offset] << 8) | data[offset + 1]);
    }

    private static int SkipName(byte[] data, int offset)
    {
        int labels = 0;
        while (true)
        {
            if (offset >= data.Length || labels++ > 127) throw new InvalidDataException("Invalid DNS name.");
            int length = data[offset++];
            if (length == 0) return offset;
            if ((length & 0xC0) == 0xC0)
            {
                if (offset >= data.Length) throw new InvalidDataException("Truncated DNS pointer.");
                int pointer = ((length & 0x3F) << 8) | data[offset++];
                if (pointer >= data.Length) throw new InvalidDataException("Invalid DNS pointer.");
                return offset;
            }
            if ((length & 0xC0) != 0 || length > 63 || offset + length > data.Length)
                throw new InvalidDataException("Invalid DNS label.");
            offset += length;
        }
    }

    public static string[] ParseAddresses(byte[] data, ushort expectedId)
    {
        if (data == null || data.Length < 12 || ReadUInt16(data, 0) != expectedId)
            throw new InvalidDataException("Invalid DNS response identifier.");
        ushort flags = ReadUInt16(data, 2);
        if ((flags & 0x8000) == 0 || (flags & 0x0200) != 0 || (flags & 0x000F) != 0)
            throw new InvalidDataException("DNS server did not return a complete successful response.");
        int questions = ReadUInt16(data, 4);
        int answers = ReadUInt16(data, 6);
        if (questions != 1 || answers > 128) throw new InvalidDataException("Invalid DNS record count.");
        int offset = SkipName(data, 12);
        if (offset + 4 > data.Length || ReadUInt16(data, offset) != 1 || ReadUInt16(data, offset + 2) != 1)
            throw new InvalidDataException("Unexpected DNS question.");
        offset += 4;
        List<string> addresses = new List<string>();
        for (int i = 0; i < answers; i++)
        {
            offset = SkipName(data, offset);
            if (offset + 10 > data.Length) throw new InvalidDataException("Truncated DNS answer.");
            ushort type = ReadUInt16(data, offset);
            ushort recordClass = ReadUInt16(data, offset + 2);
            int length = ReadUInt16(data, offset + 8);
            offset += 10;
            if (offset + length > data.Length) throw new InvalidDataException("Truncated DNS data.");
            if (type == 1 && recordClass == 1 && length == 4)
            {
                string address = new IPAddress(new byte[] { data[offset], data[offset + 1], data[offset + 2], data[offset + 3] }).ToString();
                if (!addresses.Contains(address)) addresses.Add(address);
            }
            offset += length;
        }
        return addresses.ToArray();
    }
}
