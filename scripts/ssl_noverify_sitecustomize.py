"""
sitecustomize.py — Disable SSL certificate verification globally.

Loaded automatically by Python when the directory containing this file
is on PYTHONPATH. Only used in corporate networks where a TLS-inspecting
proxy re-signs HTTPS traffic with an internal CA that containers don't trust.

DO NOT use in production. Set SKIP_SSL_VERIFY=false to disable.
"""
import os

if os.environ.get("SKIP_SSL_VERIFY", "false").lower() == "true":
    import ssl

    # Make the default HTTPS context skip certificate verification
    ssl._create_default_https_context = ssl._create_unverified_context

    # Patch urllib3 (used by requests) to disable verification by default
    try:
        import urllib3
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    except Exception:
        pass
