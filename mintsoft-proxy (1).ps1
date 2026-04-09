param(
  [string]$ApiKey = "",
  [int]   $Port   = 8787
)

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Proxy running on http://localhost:$Port  (Ctrl-C to stop)" -ForegroundColor Cyan

function Invoke-Upstream {
  param($res, $fwdRes)
  if ($null -eq $fwdRes) {
    $res.StatusCode = 504
    $b = [System.Text.Encoding]::UTF8.GetBytes("Gateway timeout")
    $res.OutputStream.Write($b, 0, $b.Length)
    return
  }
  $res.StatusCode = [int]$fwdRes.StatusCode
  if ($fwdRes.ContentType) { $res.ContentType = $fwdRes.ContentType }
  try { $fwdRes.GetResponseStream().CopyTo($res.OutputStream) } catch {}
  try { $fwdRes.Close() } catch {}
}

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  $req = $ctx.Request
  $res = $ctx.Response

  $res.Headers.Add("Access-Control-Allow-Origin",  "*")
  $res.Headers.Add("Access-Control-Allow-Headers", "ms-apikey,Authorization,Content-Type,Accept")
  $res.Headers.Add("Access-Control-Allow-Methods", "GET,PUT,POST,PATCH,DELETE,OPTIONS")
  $res.Headers.Add("Access-Control-Allow-Private-Network", "true")

  if ($req.HttpMethod -eq "OPTIONS") { $res.StatusCode = 204; $res.Close(); continue }

  $path = $req.Url.PathAndQuery

  # --- GitHub API ---
  if ($path.StartsWith("/gh-api/")) {
    $target = "https://api.github.com/" + $path.Substring("/gh-api/".Length)
    try {
      [System.Net.HttpWebRequest]$hw = [System.Net.WebRequest]::Create($target)
      $hw.Method    = $req.HttpMethod
      $hw.Accept    = "application/vnd.github+json"
      $hw.UserAgent = "MintSoft-KPI-Proxy/1.0"
      $hw.Timeout   = 15000

      $auth = $req.Headers["Authorization"]
      if ($auth) { $hw.Headers["Authorization"] = $auth }

      if ($req.HasEntityBody -and ($req.HttpMethod -in @("PUT","POST","PATCH"))) {
        $hw.ContentType = "application/json"
        $body  = [System.IO.StreamReader]::new($req.InputStream).ReadToEnd()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $hw.ContentLength = $bytes.Length
        $reqStream = $hw.GetRequestStream()
        $reqStream.Write($bytes, 0, $bytes.Length)
        $reqStream.Close()
      }

      $fwdRes = $null
      try   { $fwdRes = $hw.GetResponse() }
      catch [System.Net.WebException] {
        $fwdRes = $_.Exception.Response
        Write-Host "GitHub error: $($_.Exception.Message)" -ForegroundColor Yellow
      }

      Invoke-Upstream $res $fwdRes
    } catch {
      Write-Host "GitHub fatal: $_" -ForegroundColor Red
      try { $res.StatusCode = 502 } catch {}
    }
    try { $res.Close() } catch {}
    continue
  }

  # --- Mintsoft API ---
  if ($path.StartsWith("/api/")) {
    $target = "https://api.mintsoft.co.uk" + $path
    try {
      $hw = [System.Net.WebRequest]::Create($target)
      $hw.Method  = $req.HttpMethod
      $hw.Accept  = "application/json"
      $hw.Timeout = 30000

      $key = if ($ApiKey) { $ApiKey } else { $req.Headers["ms-apikey"] }
      if ($key) { $hw.Headers["ms-apikey"] = $key }

      $fwdRes = $null
      try   { $fwdRes = $hw.GetResponse() }
      catch [System.Net.WebException] {
        $fwdRes = $_.Exception.Response
        Write-Host "Mintsoft error: $($_.Exception.Message)" -ForegroundColor Yellow
      }

      Invoke-Upstream $res $fwdRes
    } catch {
      Write-Host "Mintsoft fatal: $_" -ForegroundColor Red
      try { $res.StatusCode = 502 } catch {}
    }
    try { $res.Close() } catch {}
    continue
  }

  $res.StatusCode = 404
  $res.Close()
}
