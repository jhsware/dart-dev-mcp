// Shared constants ported from Python apple-mail-mcp/constants.py.

/// Newsletter platform sender patterns (lowercase substrings).
const List<String> newsletterPlatformPatterns = [
  'substack.com',
  'mailchimp.com',
  'sendgrid.net',
  'constantcontact.com',
  'campaign-archive.com',
  'list-manage.com',
  'mailgun.org',
  'sendinblue.com',
  'convertkit.com',
  'beehiiv.com',
  'buttondown.email',
  'revue.email',
];

/// Newsletter keyword sender patterns (lowercase substrings).
const List<String> newsletterKeywordPatterns = [
  'newsletter',
  'digest',
  'weekly',
  'daily',
  'update',
  'bulletin',
  'dispatch',
  'briefing',
  'roundup',
  'noreply',
  'no-reply',
];

/// System folders to skip when searching "All" mailboxes.
const List<String> skipFolders = [
  'Trash',
  'Junk',
  'Spam',
  'Sent',
  'Sent Messages',
  'Drafts',
  'Deleted Messages',
  'Deleted Items',
  'Archive',
  'Notes',
];

/// Common email thread subject prefixes to strip for matching.
const List<String> threadPrefixes = [
  'Re: ',
  'RE: ',
  'Fwd: ',
  'FW: ',
  'Fw: ',
];

/// Maps human-friendly time range names to days-back values.
/// 0 means "all time" (no date filter).
const Map<String, int> timeRanges = {
  'today': 1,
  'yesterday': 2,
  'week': 7,
  'month': 30,
  'quarter': 90,
  'year': 365,
  'all': 0,
};

/// Default fields returned by the list-emails operation.
const List<String> defaultEmailFields = [
  'sender',
  'subject',
  'date',
  'message_id',
];

/// All available fields that can be requested from list-emails.
const List<String> allEmailFields = [
  'sender',
  'subject',
  'date',
  'message_id',
  'read_status',
  'mailbox',
  'account',
  'attachments',

];