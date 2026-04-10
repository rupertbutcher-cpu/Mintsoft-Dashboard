param(
    [int]    $Port   = 8787,
    [string] $ApiKey = ""
)

$MintSoftBase = "https://api.mintsoft.co.uk"
$Prefix       = "http://localhost:" + $Port + "/"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Prefix)
$listener.Start()

Write-Host ""
Write-Host "  Mintsoft CORS Proxy running on $Prefix" -ForegroundColor Cyan
Write-Host "  Forwarding to: $MintSoftBase" -ForegroundColor Gray
Write-Host "  Press Ctrl+C to stop." -ForegroundColor Gray
Write-Host ""

function Send-CorsHeaders($res) {
    try { $res.Headers.Add("Access-Control-Allow-Origin",  "*") }           catch {}
    try { $res.Headers.Add("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS") } catch {}
    try { $res.Headers.Add("Access-Control-Allow-Headers", "ms-apikey, Content-Type, Accept, Authorization") } catch {}
    try { $res.Headers.Add("Access-Control-Expose-Headers","*") }           catch {}
}

try {
    while ($true) {

        # Block until a request arrives (this is synchronous \u2014 no polling needed)
        $ctx = $null
        try {
            $ctx = $listener.GetContext()
        } catch {
            # Listener was stopped (Ctrl+C) \u2014 exit cleanly
            break
        }

        $req = $ctx.Request
        $res = $ctx.Response

        Write-Host ("  " + $req.HttpMethod + " " + $req.Url.PathAndQuery) -ForegroundColor DarkGray

        # \u2500\u2500 CORS preflight \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
        if ($req.HttpMethod -eq "OPTIONS") {
            $res.StatusCode = 204
            Send-CorsHeaders $res
            $res.Close()
            continue
        }

        # \u2500\u2500 Proxy the request \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
        # Route /gh-api/ to GitHub, everything else to Mintsoft
        $pathAndQuery = $req.Url.PathAndQuery
        if ($pathAndQuery.StartsWith('/gh-api/')) {
            $ghPath    = $pathAndQuery.Substring(8)
            $targetUrl = 'https://api.github.com/' + $ghPath
        } else {
            $targetUrl = $MintSoftBase + $pathAndQuery
        }

        try {
            $upstream = [System.Net.HttpWebRequest]::Create($targetUrl)
            $upstream.Method               = $req.HttpMethod
            $upstream.Timeout              = 90000
            $upstream.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

            # \u2500\u2500 Forward headers \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
            foreach ($hdr in $req.Headers.AllKeys) {
                $val      = $req.Headers[$hdr]
                $hdrLower = $hdr.ToLower()

                if ($hdrLower -eq "ms-apikey") {
                    $keyToUse = if ($ApiKey -ne "") { $ApiKey } else { $val }
                    $upstream.Headers.Add("ms-apikey", $keyToUse)
                } elseif ($hdrLower -eq "accept") {
                    $upstream.Accept = $val
                } elseif ($hdrLower -eq "content-type") {
                    $upstream.ContentType = $val
                } elseif ($hdrLower -eq "authorization") {
                    # Authorization is a restricted header in .NET -- must be set directly
                    try { $upstream.Headers["Authorization"] = $val } catch {}
                } elseif ($hdrLower -in @("host", "connection", "transfer-encoding", "accept-encoding")) {
                    # skip \u2014 let .NET handle these
                } else {
                    try { $upstream.Headers.Add($hdr, $val) } catch {}
                }
            }

            # Inject key if not already set
            if ($ApiKey -ne "" -and $req.Headers["ms-apikey"] -eq $null) {
                $upstream.Headers.Add("ms-apikey", $ApiKey)
            }

            # \u2500\u2500 Forward request body \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
            if ($req.HasEntityBody) {
                $upstream.ContentLength = $req.ContentLength64
                $bodyBytes = New-Object byte[] $req.ContentLength64
                [void]$req.InputStream.Read($bodyBytes, 0, $bodyBytes.Length)
                $upReqStream = $upstream.GetRequestStream()
                $upReqStream.Write($bodyBytes, 0, $bodyBytes.Length)
                $upReqStream.Close()
            }

            # \u2500\u2500 Get upstream response \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
            $upResponse = $null
            try {
                $upResponse = $upstream.GetResponse()
            } catch [System.Net.WebException] {
                if ($_.Exception.Response -ne $null) {
                    $upResponse = $_.Exception.Response
                } else {
                    throw
                }
            }

            # \u2500\u2500 Read decompressed body \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
            $upStream  = $upResponse.GetResponseStream()
            $reader    = New-Object System.IO.StreamReader($upStream, [System.Text.Encoding]::UTF8)
            $bodyText  = $reader.ReadToEnd()
            $reader.Close()
            $upResponse.Close()

            # \u2500\u2500 Write response to browser \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyText)
            $res.StatusCode      = [int]$upResponse.StatusCode
            $res.ContentType     = "application/json; charset=utf-8"
            $res.ContentLength64 = $bodyBytes.Length
            Send-CorsHeaders $res
            $res.OutputStream.Write($bodyBytes, 0, $bodyBytes.Length)

        } catch {
            Write-Host ("  ERROR: " + $_.Exception.Message) -ForegroundColor Red
            $errMsg   = $_.Exception.Message -replace '"', "'"
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"' + $errMsg + '"}')
            try {
                $res.StatusCode      = 502
                $res.ContentType     = "application/json; charset=utf-8"
                $res.ContentLength64 = $errBytes.Length
                Send-CorsHeaders $res
                $res.OutputStream.Write($errBytes, 0, $errBytes.Length)
            } catch {}
        }

        try { $res.Close() } catch {}
    }
} finally {
    try { $listener.Stop() } catch {}
    Write-Host "Proxy stopped." -ForegroundColor Yellow
}
