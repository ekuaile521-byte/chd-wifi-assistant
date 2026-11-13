using System;
using System.Security.Cryptography;
using System.Text;

public static class ChdSrunCrypto
{
    private const string StandardBase64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    private const string PortalBase64 = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA";

    // The portal packs JavaScript character codes into little-endian 32-bit words.
    private static uint[] Pack(string text, bool includeLength)
    {
        var words = new uint[(text.Length + 3) / 4 + (includeLength ? 1 : 0)];
        for (int index = 0; index < text.Length; index++)
            words[index / 4] |= (uint)text[index] << (8 * (index % 4));
        if (includeLength)
            words[words.Length - 1] = (uint)text.Length;
        return words;
    }

    public static string EncodeInfo(string json, string challenge)
    {
        uint[] words = Pack(json, true);
        uint[] key = Pack(challenge, false);
        if (key.Length < 4)
            Array.Resize(ref key, 4);

        unchecked
        {
            uint sum = 0;
            uint previous = words[words.Length - 1];
            int rounds = 6 + 52 / words.Length;
            for (int round = 0; round < rounds; round++)
            {
                sum += 0x9E3779B9u;
                int e = (int)((sum >> 2) & 3);
                for (int index = 0; index < words.Length; index++)
                {
                    uint next = words[(index + 1) % words.Length];
                    uint mix = ((previous >> 5) ^ (next << 2))
                        + ((next >> 3) ^ (previous << 4) ^ (sum ^ next))
                        + (key[(index & 3) ^ e] ^ previous);
                    previous = words[index] += mix;
                }
            }
        }

        var bytes = new byte[words.Length * 4];
        for (int index = 0; index < bytes.Length; index++)
            bytes[index] = (byte)(words[index / 4] >> (8 * (index % 4)));

        var encoded = Convert.ToBase64String(bytes).ToCharArray();
        for (int index = 0; index < encoded.Length; index++)
        {
            int alphabetIndex = StandardBase64.IndexOf(encoded[index]);
            if (alphabetIndex >= 0)
                encoded[index] = PortalBase64[alphabetIndex];
        }
        return "{SRBX1}" + new string(encoded);
    }

    private static string Hex(byte[] digest)
    {
        return BitConverter.ToString(digest).Replace("-", "").ToLowerInvariant();
    }

    public static string PasswordDigest(string password, string challenge)
    {
        using (var hmac = new HMACMD5(Encoding.UTF8.GetBytes(challenge)))
            return Hex(hmac.ComputeHash(Encoding.UTF8.GetBytes(password)));
    }

    public static string Checksum(string challenge, string[] fields)
    {
        var source = new StringBuilder();
        foreach (string field in fields)
            source.Append(challenge).Append(field);
        using (var sha = SHA1.Create())
            return Hex(sha.ComputeHash(Encoding.UTF8.GetBytes(source.ToString())));
    }
}
