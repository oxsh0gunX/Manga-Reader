import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'native.dart';

/// About page: a separate, clean page reached from Settings — never from
/// the reading page, so the reader itself stays free of any developer
/// branding, watermark or promotion.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const String developer = 'Safvan';
  static const String email = 'safvanmbn@gmail.com';
  static const String github = 'https://github.com/oxsh0gunX';
  static const String version = '2.3.0';

  Future<void> _contact(BuildContext context) async {
    try {
      await NativeBridge.mailto(email);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('No email app found. Email: $email'),
          action: SnackBarAction(
            label: 'Copy',
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: email));
            },
          ),
        ),
      );
    }
  }

  Future<void> _github(BuildContext context) async {
    try {
      await NativeBridge.openUrl(github);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not open GitHub. Link: $github'),
          action: SnackBarAction(
            label: 'Copy',
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: github));
            },
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.asset(
                'assets/app_icon.png',
                width: 96,
                height: 96,
                errorBuilder: (ctx, _, __) => Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(Icons.picture_as_pdf_outlined, size: 48),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'PDF Reader',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Version $version',
              style: TextStyle(
                fontSize: 14,
                color: theme.colorScheme.onSurface.withOpacity(0.65),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'A premium, minimal PDF and comic reader that works fully '
              'offline. Import PDFs, read them in your own order, page by '
              'page or panel by panel — with your progress remembered.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, height: 1.5),
            ),
            const SizedBox(height: 28),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.dividerColor.withOpacity(0.6)),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.person_outlined),
                    title: const Text('Developer'),
                    subtitle: const Text(developer),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.email_outlined),
                    title: const Text('Email'),
                    subtitle: const Text(email),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.open_in_new),
                    title: const Text('GitHub'),
                    subtitle: const Text(github),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _contact(context),
                icon: const Icon(Icons.email_outlined, size: 20),
                label: const Text('Contact Developer'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _github(context),
                icon: const Icon(Icons.open_in_new, size: 20),
                label: const Text('GitHub Profile'),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              '© 2026 $developer. All rights reserved.',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
