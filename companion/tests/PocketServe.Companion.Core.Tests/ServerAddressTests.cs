namespace PocketServe.Companion.Core.Tests;

using PocketServe.Companion.Core;
using Shouldly;

[TestFixture]
public sealed class ServerAddressTests
{
    [Test]
    public void TryParse_BareHost_DefaultsPort8080()
    {
        var ok = ServerAddress.TryParse("192.168.68.27", "", out var address);

        ok.ShouldBeTrue();
        address.ShouldNotBeNull();
        address.Host.ShouldBe("192.168.68.27");
        address.Port.ShouldBe(8080);
        address.BaseUrl.ShouldBe("http://192.168.68.27:8080");
    }

    [Test]
    public void TryParse_ExplicitPort_Wins()
    {
        var ok = ServerAddress.TryParse("10.0.0.5", "8081", out var address);

        ok.ShouldBeTrue();
        address!.Port.ShouldBe(8081);
    }

    [TestCase("http://192.168.68.27:8080")]
    [TestCase("http://192.168.68.27:8080/")]
    [TestCase("  http://192.168.68.27:8080/health  ")]
    public void TryParse_PastedUrl_ExtractsHostAndPort(string input)
    {
        var ok = ServerAddress.TryParse(input, "", out var address);

        ok.ShouldBeTrue();
        address!.Host.ShouldBe("192.168.68.27");
        address.Port.ShouldBe(8080);
    }

    [Test]
    public void TryParse_UrlWithNonDefaultPort_KeepsIt()
    {
        var ok = ServerAddress.TryParse("http://192.168.68.27:9090", "", out var address);

        ok.ShouldBeTrue();
        address!.Port.ShouldBe(9090);
    }

    [Test]
    public void TryParse_Whitespace_Trims()
    {
        var ok = ServerAddress.TryParse("  192.168.68.27  ", "  8080 ", out var address);

        ok.ShouldBeTrue();
        address!.Host.ShouldBe("192.168.68.27");
        address.Port.ShouldBe(8080);
    }

    [TestCase("")]
    [TestCase("   ")]
    [TestCase(null)]
    public void TryParse_EmptyHost_Fails(string? input)
    {
        ServerAddress.TryParse(input, "", out var address).ShouldBeFalse();
        address.ShouldBeNull();
    }

    [TestCase("0")]
    [TestCase("70000")]
    [TestCase("abc")]
    [TestCase("-1")]
    public void TryParse_InvalidPort_Fails(string port)
    {
        ServerAddress.TryParse("192.168.68.27", port, out var address).ShouldBeFalse();
    }

    [Test]
    public void TryParse_HostWithSlashOrSpace_Fails()
    {
        ServerAddress.TryParse("192.168.68.27/api", "", out _).ShouldBeFalse();
    }
}
