using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;

namespace Voiceling.Core;

/// Authenticated PCM16/16kHz decoder. No audio files are created.
public static class DeviceAudio
{
    public const int MaximumSamples = 60 * 16000;
    public static float[] Decode(JsonElement body, string session, byte[] key)
    {
        if (session.Length != 32 || key.Length != 32 || body.GetProperty("session").GetString() != session)
            throw new InvalidDataException("Invalid device recording");
        var id = Convert.FromHexString(session);
        var rows = body.GetProperty("packets").EnumerateArray().ToArray();
        if (rows.Length < 3 || rows.Length > 471) throw new InvalidDataException("Invalid recording length");
        var samples = new List<float>();
        byte[] context = [.. "deskling-mic-session-v1|"u8, .. id];
        byte[] sessionKey = HMACSHA256.HashData(key, context);
        using var aes = new AesGcm(sessionKey, 16);
        CryptographicOperations.ZeroMemory(sessionKey);
        for (int i = 0; i < rows.Length; i++)
        {
            byte[] p = Convert.FromBase64String(rows[i].GetString()!);
            int count = p.Length - 93;
            byte kind = i == 0 ? (byte)0 : i == rows.Length - 1 ? (byte)2 : (byte)1;
            if (count < 0 || count > 4096 || count % 2 != 0 || (kind == 1 ? count == 0 : count != 0) ||
                !p.AsSpan(0, 4).SequenceEqual("DMA1"u8) || p[4] != kind ||
                !p.AsSpan(5, 16).SequenceEqual(id) || BinaryPrimitives.ReadUInt32LittleEndian(p.AsSpan(21, 4)) != i ||
                !p.AsSpan(33, 8).SequenceEqual(id.AsSpan(0, 8)) || BinaryPrimitives.ReadUInt32LittleEndian(p.AsSpan(41, 4)) != i ||
                samples.Count + count / 2 > MaximumSamples)
                throw new InvalidDataException("Incomplete device recording");
            byte[] pcm = new byte[count];
            try
            {
                aes.Decrypt(p.AsSpan(33, 12), p.AsSpan(45, count), p.AsSpan(45 + count, 16), pcm, p.AsSpan(0, 33));
                for (int n = 0; n < count; n += 2)
                    samples.Add(BinaryPrimitives.ReadInt16LittleEndian(pcm.AsSpan(n, 2)) / 32768f);
            }
            finally { CryptographicOperations.ZeroMemory(pcm); }
        }
        return samples.ToArray();
    }
}
