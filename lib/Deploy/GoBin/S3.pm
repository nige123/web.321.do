package Deploy::GoBin::S3;

use Mojo::Base -base, -signatures;

has [qw(bucket creds)];

# S3 boundary. Real aws-CLI shell-out lands in Task 8; this stub keeps the
# command compiling and the seam injectable in tests.
sub put  ($self, %a) { return { ok => 1 } }
sub get  ($self, %a) { return { ok => 0, content => undef } }
sub head ($self, %a) { return { ok => 0 } }

1;
