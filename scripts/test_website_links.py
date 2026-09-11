"""Exercise the HTTPS destinations used by Settings and the paywall."""
from pathlib import Path
import re
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

class OfficialWebsiteLinkTests(unittest.TestCase):
    def test_settings_and_paywall_links_open_current_official_pages(self):
        consumers = {
            'Modules/Features/Settings/ProfileView.swift': {
                'privacyPolicyURL': '/privacy', 'userAgreementURL': '/terms'},
            'Modules/Features/Subscription/PaywallView.swift': {'privacyPolicyURL': '/privacy'},
        }
        for filename, fields in consumers.items():
            source = (ROOT / filename).read_text()
            for field, path in fields.items():
                with self.subTest(view=filename, field=field):
                    url = re.search(r'let '+field+r' = URL\(string: "([^"]+)"\)', source).group(1)
                    self.assertEqual(url, 'https://yuedureader.com' + path)
                    request = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (compatible; YueduLinkRegression/1.0)'})
                    with urllib.request.urlopen(request, timeout=30) as response:
                        html = response.read().decode()
                        self.assertEqual(response.status, 200)
                        self.assertEqual(response.url, url)
                        self.assertIn('rel="canonical" href="'+url+'"', html)
                        self.assertIn('<h1', html)

    def test_paywall_still_uses_apple_standard_eula(self):
        source = (ROOT / 'Modules/Features/Subscription/PaywallView.swift').read_text()
        settings = (ROOT / 'Modules/Features/Settings/ProfileView.swift').read_text()
        self.assertIn('private let paidTermsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")', settings)
        url = re.search(r'let paidTermsURL = URL\(string: "([^"]+)"\)', source).group(1)
        self.assertEqual(url, 'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/')
        with urllib.request.urlopen(url, timeout=30) as response:
            self.assertEqual(response.status, 200)
            self.assertIn('LICENSED APPLICATION END USER LICENSE AGREEMENT', response.read().decode())

if __name__ == '__main__':
    unittest.main(verbosity=2)
