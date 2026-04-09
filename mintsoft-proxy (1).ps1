param(
  [string]$ApiKey  = "",
  [int]   $Port    = 8787
)

# ── Mintsoft Despatch KPI Dashboard — Local Proxy ──────────────────────────
# Forwards:
#   /api/*     → https://api.mintsoft.co.uk/api/*   (Mintsoft API)
#   /gh-api/*  → https://api.github.com/*            (GitHub API for history sync)
# ─────────────────────────────────────────────────────────────────────────────

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Proxy running on http://localhost:$Port  (Ctrl-C to stop)" -ForegroundColor Cyan

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  $req = $ctx.Request
  $res = $ctx.Response

  # ── CORS pre-flight ──────────────────────────────────────────────────────
  $res.Headers.Add("Access-Control-Allow-Origin",  "*")
  $res.Headers.Add("Access-Control-Allow-Headers", "ms-apikey,Authorization,Content-Type,Accept")
  $res.Headers.Add("Access-Control-Allow-Methods", "GET,PUT,POST,PATCH,DELETE,OPTIONS")

  if ($req.HttpMethod -eq "OPTIONS") {
    $res.StatusCode = 204
    $res.Close()
    continue
  }

  $path = $req.Url.PathAndQuery

  # ── Route: GitHub API ────────────────────────────────────────────────────
  if ($path.StartsWith("/gh-api/")) {
    $target = "https://api.github.com/" + $path.Substring("/gh-api/".Length)
    try {
      $fwdReq = [System.Net.WebRequest]::Create($target)
      $fwdReq.Method = $req.HttpMethod
      $fwdReq.Accept = "application/vnd.github+json"
      $fwdReq.Headers.Add("User-Agent", "MintSoft-KPI-Proxy/1.0")

      # Forward Authorization header (GitHub token)
      $authHdr = $req.Headers["Authorization"]
      if ($authHdr) { $fwdReq.Headers.Add("Authorization", $authHdr) }

      if ($req.HasEntityBody -and $req.HttpMethod -in @("PUT","POST","PATCH")) {
        $fwdReq.ContentType = "application/json"
        $body = [System.IO.StreamReader]::new($req.InputStream).ReadToEnd()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $fwdReq.ContentLength = $bytes.Length
        $fwdReq.GetRequestStream().Write($bytes, 0, $bytes.Length)
      }

      try {
        $fwdRes = $fwdReq.GetResponse()
      } catch [System.Net.WebException] {
        $fwdRes = $_.Exception.Response
      }

      $res.StatusCode       = [int]$fwdRes.StatusCode
      $res.ContentType      = $fwdRes.ContentType
      $fwdRes.GetResponseStream().CopyTo($res.OutputStream)
      $fwdRes.Close()
    } catch {
      $res.StatusCode = 502
      $err = [System.Text.Encoding]::UTF8.GetBytes("GitHub proxy error: $_")
      $res.OutputStream.Write($err, 0, $err.Length)
    }
    $res.Close()
    continue
  }

  # ── Route: Mintsoft API ──────────────────────────────────────────────────
  if ($path.StartsWith("/api/")) {
    $target = "https://api.mintsoft.co.uk" + $path
    try {
      $fwdReq = [System.Net.WebRequest]::Create($target)
      $fwdReq.Method  = $req.HttpMethod
      $fwdReq.Accept  = "application/json"

      # Use baked-in key if provided, otherwise forward from request header
      $key = if ($ApiKey) { $ApiKey } else { $req.Headers["ms-apikey"] }
      if ($key) { $fwdReq.Headers.Add("ms-apikey", $key) }

      try {
        $fwdRes = $fwdReq.GetResponse()
      } catch [System.Net.WebException] {
        $fwdRes = $_.Exception.Response
      }

      $res.StatusCode  = [int]$fwdRes.StatusCode
      $res.ContentType = $fwdRes.ContentType
      $fwdRes.GetResponseStream().CopyTo($res.OutputStream)
      $fwdRes.Close()
    } catch {
      $res.StatusCode = 502
      $err = [System.Text.Encoding]::UTF8.GetBytes("Mintsoft proxy error: $_")
      $res.OutputStream.Write($err, 0, $err.Length)
    }
    $res.Close()
    continue
  }

  # ── 404 for anything else ────────────────────────────────────────────────
  $res.StatusCode = 404
  $res.Close()
}
