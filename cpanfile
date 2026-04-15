requires 'perl', '5.042';

requires 'Mojolicious';
requires 'YAML::XS';
requires 'Path::Tiny';
requires 'Text::Markdown';

# Service controller — Deploy::Service shells to `ubic restart`
# and Deploy::Ubic-generated wrapper scripts `use Ubic::Service::SimpleDaemon`.
requires 'Ubic';
requires 'Ubic::Service::SimpleDaemon';
