using SkiaSharp;
using ZXing;
using ZXing.Common;

namespace ZteImeiStudio.Windows.Esim;
public static class EsimQr
{
    public static string Read(string path)
    {
        try
        {
            if (new FileInfo(path).Length > 20 * 1024 * 1024) throw new EsimException();
            using var stream = File.OpenRead(path);
            using var codec = SKCodec.Create(stream);
            if (codec is null || codec.Info.Width < 1 || codec.Info.Height < 1 || (long)codec.Info.Width * codec.Info.Height > 16_000_000) throw new EsimException();
            using var bitmap = SKBitmap.Decode(codec, new SKImageInfo(codec.Info.Width, codec.Info.Height, SKColorType.Bgra8888, SKAlphaType.Unpremul));
            if (bitmap is null) throw new EsimException();
            var reader = new BarcodeReaderGeneric { AutoRotate = true, Options = new DecodingOptions { TryHarder = true, PossibleFormats = [BarcodeFormat.QR_CODE] } };
            var found = reader.DecodeMultiple(new RGBLuminanceSource(bitmap.Bytes, bitmap.Width, bitmap.Height, RGBLuminanceSource.BitmapFormat.BGRA32));
            if (found is not { Length: 1 } || !EsimValidation.ActivationCodeValid(found[0].Text)) throw new EsimException();
            return found[0].Text;
        }
        catch { throw new InvalidDataException("Изображение должно содержать ровно один действительный QR-код eSIM."); }
    }
}
