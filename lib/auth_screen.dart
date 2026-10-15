part of 'main.dart';

/// Sign in or create an account with email + password, or continue with Google.
/// Closes itself as soon as the store reports a signed-in user, which also covers
/// the Google flow (the session arrives later through the app's deep link).
class AuthScreen extends StatefulWidget {
  const AuthScreen({required this.store, super.key});
  final FinanceStore store;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _createAccount = false;
  bool _hidePassword = true;
  bool _busy = false;
  bool _closing = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    if (widget.store.signedIn) {
      if (_closing) return;
      _closing = true;
      Navigator.of(context).maybePop();
    } else {
      setState(() {}); // refresh the offline notice
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final email = _email.text.trim();
    final password = _password.text;
    final outcome = _createAccount
        ? await widget.store.signUpWithEmail(email, password)
        : await widget.store.signInWithEmail(email, password);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = outcome.error;
      _info = outcome.info;
      if (outcome.info != null) _createAccount = false;
    });
  }

  Future<void> _google() async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final outcome = await widget.store.signInWithGoogle();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = outcome.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final offline = !widget.store.online;
    return Scaffold(
      appBar: AppBar(title: Text(_createAccount ? 'Create account' : 'Sign in')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Back up your records and use them on any device. Anything you added while '
              'offline or signed out is kept and uploaded to your account.',
              style: TextStyle(color: _muted, height: 1.45, fontSize: 13),
            ),
            const SizedBox(height: 18),
            if (offline)
              const _AuthNotice(
                color: _red,
                icon: Icons.wifi_off_rounded,
                text: 'You are offline. Connect to the internet to sign in or create an account. Your records keep working in the meantime.',
              ),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Sign in')),
                ButtonSegment(value: true, label: Text('Create account')),
              ],
              selected: {_createAccount},
              onSelectionChanged: _busy
                  ? null
                  : (value) => setState(() {
                        _createAccount = value.first;
                        _error = null;
                        _info = null;
                      }),
            ),
            const SizedBox(height: 18),
            Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    controller: _email,
                    enabled: !_busy,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                    validator: (value) {
                      final text = value?.trim() ?? '';
                      if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text)) return 'Enter a valid email address';
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: _hidePassword,
                    autofillHints: [_createAccount ? AutofillHints.newPassword : AutofillHints.password],
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: _hidePassword ? 'Show password' : 'Hide password',
                        icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _hidePassword = !_hidePassword),
                      ),
                    ),
                    validator: (value) {
                      if ((value ?? '').length < 6) return 'Use at least 6 characters';
                      return null;
                    },
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              _AuthNotice(color: _red, icon: Icons.error_outline, text: _error!),
            ],
            if (_info != null) ...[
              const SizedBox(height: 14),
              _AuthNotice(color: _green, icon: Icons.mark_email_read_outlined, text: _info!),
            ],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _busy || offline ? null : _submit,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48), backgroundColor: _blue),
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(_createAccount ? 'Create account' : 'Sign in'),
            ),
            const SizedBox(height: 16),
            const Row(
              children: [
                Expanded(child: Divider()),
                Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('or', style: TextStyle(color: _muted, fontSize: 12))),
                Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _busy || offline ? null : _google,
              icon: const Icon(Icons.account_circle_outlined),
              label: const Text('Continue with Google'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: _ink),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthNotice extends StatelessWidget {
  const _AuthNotice({required this.color, required this.icon, required this.text});
  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(color: _ink, fontSize: 12.5, height: 1.4))),
          ],
        ),
      );
}
