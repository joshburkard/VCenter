function Get-VCenterCertificate {
    <#
        .SYNOPSIS
            returns infos about a web certificate

        .PARAMETER URI
            defines the URI to request

            this string parameter is mandatory

        .EXAMPLE
            Get-VCenterCertificate -URI 'https://www.google.com'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $URI
    )
    if ( -not ( 'IDontCarePolicy' -as [type] ) ) {
    add-type @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
            public class IDontCarePolicy : ICertificatePolicy {
            public IDontCarePolicy() {}
            public bool CheckValidationResult(
                ServicePoint sPoint, X509Certificate cert,
                WebRequest wRequest, int certProb) {
                return true;
            }
        }
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = new-object IDontCarePolicy
    # Need to do simple GET connection for this method to work
    Invoke-RestMethod -Uri $URI -Method Get | Out-Null

    $endpoint_request = [System.Net.Webrequest]::Create($URI)
    # Get Thumbprint + add colons for a valid Thumbprint
    $Certificate = $endpoint_request.ServicePoint.Certificate
    $Thumbprint = ($endpoint_request.ServicePoint.Certificate.GetCertHashString()) -replace '(..(?!$))','$1:'

    $ret = [PSCustomObject]@{
        Issuer = $Certificate.Issuer
        Subject = $Certificate.Subject
        Thumbprint = $Thumbprint
        Handle = $Certificate.Handle
    }
    return $ret
}