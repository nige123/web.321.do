package Deploy::GoBin::Runner;

use Mojo::Base -base, -signatures;

# GoReleaser boundary. Real shell-out lands with the S3 client (Task 8);
# this stub keeps the command compiling and the seam injectable in tests.
sub run ($self, %a) { return { ok => 1, output => '' } }

1;
