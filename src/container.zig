const std = @import("std");
const testing = std.testing;

const HashMap = std.json.ArrayHashMap(Empty);

pub const ConfigFile = struct {
    architecture: []const u8,
    author: ?[]const u8 = null,
    container: ?[]const u8 = null,
    created: ?[]const u8 = null,
    docker_version: ?[]const u8 = null,
    history: ?[]const History = null,
    os: []const u8,
    rootfs: RootFS,
    config: ?Config = null,
    @"os.version": ?[]const u8 = null,
    variant: ?[]const u8 = null,
    @"os.features": ?[][]const u8 = null,
};

pub const History = struct {
    author: ?[]const u8 = null,
    created: ?[]const u8 = null,
    created_by: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    empty_layer: ?bool = null,
};

pub const RootFS = struct {
    type: []const u8,
    diff_ids: [][]const u8,
};

pub const Empty = struct {};

pub const Config = struct {
    AttachStderr: ?bool = null,
    AttachStdin: ?bool = null,
    AttachStdout: ?bool = null,
    Cmd: ?[][]const u8 = null,
    Healthcheck: ?HealthCheck = null,
    Domainname: ?[]const u8 = null,
    Entrypoint: ?[][]const u8 = null,
    Env: ?[][]const u8 = null,
    Hostname: ?[]const u8 = null,
    Image: ?[]const u8 = null,
    Labels: ?HashMap = null,
    OnBuild: ?[][]const u8 = null,
    OpenStdin: ?bool = null,
    StdinOnce: ?bool = null,
    Tty: ?bool = null,
    User: ?[]const u8 = null,
    Volumes: ?HashMap = null,
    WorkingDir: ?[]const u8 = null,
    ExposedPorts: ?HashMap = null,
    ArgsEscaped: ?bool = null,
    NetworkDisabled: ?bool = null,
    MacAddress: ?[]const u8 = null,
    StopSignal: ?[]const u8 = null,
    Shell: ?[][]const u8 = null,
};

pub const HealthCheck = struct {
    Test: ?[][]const u8 = null,
    Interval: ?u64 = null,
    Timeout: ?u64 = null,
    StartPeriod: ?u64 = null,
    Retries: ?i64 = null,
};

test "json" {
    const json_string =
        \\{"architecture":"amd64","created":"2024-05-09T18:58:11Z","history":[{"created":"2024-05-09T18:58:11Z","created_by":"/bin/sh -c #(nop) ADD file:258da966e49fd81eb3befac4ebcc023feb92794e891d5c9ca9b61084c7a209d5 in / "},{"created":"2024-05-09T18:58:11Z","created_by":"/bin/sh -c #(nop)  CMD [\"bash\"]","empty_layer":true},{"created":"2024-05-09T18:58:11Z","created_by":"RUN /bin/sh -c set -eux; \tgroupadd -r postgres --gid=999; \tuseradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \tmkdir -p /var/lib/postgresql; \tchown -R postgres:postgres /var/lib/postgresql # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2024-05-09T18:58:11Z","created_by":"RUN /bin/sh -c set -ex; \tapt-get update; \tapt-get install -y --no-install-recommends \t\tgnupg \t\tless \t; \trm -rf /var/lib/apt/lists/* # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2024-05-09T18:58:11Z","created_by":"ENV GOSU_VERSION=1.17","comment":"buildkit.dockerfile.v0","empty_layer":true},{"created":"2024-05-09T18:58:11Z","created_by":"RUN /bin/sh -c set -eux; \tsavedAptMark=\"$(apt-mark showmanual)\"; \tapt-get update; \tapt-get install -y --no-install-recommends ca-certificates wget; \trm -rf /var/lib/apt/lists/*; \tdpkgArch=\"$(dpkg --print-architecture | awk -F- '{ print $NF }')\"; \twget -O /usr/local/bin/gosu \"https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch\"; \twget -O /usr/local/bin/gosu.asc \"https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc\"; \texport GNUPGHOME=\"$(mktemp -d)\"; \tgpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \tgpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \tgpgconf --kill all; \trm -rf \"$GNUPGHOME\" /usr/local/bin/gosu.asc; \tapt-mark auto '.*' \u003e /dev/null; \t[ -z \"$savedAptMark\" ] || apt-mark manual $savedAptMark \u003e /dev/null; \tapt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \tchmod +x /usr/local/bin/gosu; \tgosu --version; \tgosu nobody true # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2024-05-09T18:58:11Z","created_by":"RUN /bin/sh -c set -eux; \tif [ -f /etc/dpkg/dpkg.cfg.d/docker ]; then \t\tgrep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \t\tsed -ri '/\\/usr\\/share\\/locale/d' /etc/dpkg/dpkg.cfg.d/docker; \t\t! grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \tfi; \tapt-get update; apt-get install -y --no-install-recommends locales; rm -rf /var/lib/apt/lists/*; \techo 'en_US.UTF-8 UTF-8' \u003e\u003e /etc/locale.gen; \tlocale-gen; \tlocale -a | grep 'en_US.utf8' # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2024-05-09T18:58:11Z","created_by":"ENV LANG=en_US.utf8","comment":"buildkit.dockerfile.v0","empty_layer":true},{"created":"2024-05-09T18:58:11Z","created_by":"RUN /bin/sh -c set -eux; \tapt-get update; \tapt-get install -y --no-install-recommends \t\tlibnss-wrapper \t\txz-utils \t\tzstd \t; \trm -rf /var/lib/apt/lists/* # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2024-05-09T18:58:11Z","created_by":"RUN /bin/sh -c mkdir /docker-entrypoint-initdb.d # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2024-05-09T18:58:11Z","created_by":"RUN /bin/sh -c set -ex; \tkey='B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8'; \texport GNUPGHOME=\"$(mktemp -d)\"; \tmkdir -p /usr/local/share/keyrings/; \tgpg --batch --keyserver keyserver.ubuntu.com --recv-keys \"$key\"; \tgpg --batch --export --armor \"$key\" \u003e /usr/local/share/keyrings/postgres.gpg.asc; \tgpgconf --kill all; \trm -rf \"$GNUPGHOME\" # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2024-05-09T18:58:11Z","created_by":"ENV PG_MAJOR=16","comment":"buildkit.dockerfile.v0","empty_layer":true},{"created":"2024-05-09T18:58:11Z","created_by":"ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/lib/postgresql/16/bin","comment":"buildkit.dockerfile.v0","empty_layer":true},{"created":"2024-05-09T18:58:11Z","created_by":"ENV PG_VERSION=16.3-1.pgdg110+1","comment":"buildkit.dockerfile.v0","empty_layer":true},{"created":"2024-05-09T18:58:11Z","created_by":"RUN /bin/sh -c set -ex; \t\texport PYTHONDONTWRITEBYTECODE=1; \t\tdpkgArch=\"$(dpkg --print-architecture)\"; \taptRepo=\"[ signed-by=/usr/local/share/keyrings/postgres.gpg.asc ] http://apt.postgresql.org/pub/repos/apt/ bullseye-pgdg main $PG_MAJOR\"; \tcase \"$dpkgArch\" in \t\tamd64 | arm64 | ppc64el | s390x) \t\t\techo \"deb $aptRepo\" \u003e /etc/apt/sources.list.d/pgdg.list; \t\t\tapt-get update; \t\t\t;; \t\t*) \t\t\techo \"deb-src $aptRepo\" \u003e /etc/apt/sources.list.d/pgdg.list; \t\t\t\t\t\tsavedAptMark=\"$(apt-mark showmanual)\"; \t\t\t\t\t\ttempDir=\"$(mktemp -d)\"; \t\t\tcd \"$tempDir\"; \t\t\t\t\t\tapt-get update; \t\t\tapt-get install -y --no-install-recommends dpkg-dev; \t\t\techo \"deb [ trusted=yes ] file://$tempDir ./\" \u003e /etc/apt/sources.list.d/temp.list; \t\t\t_update_repo() { \t\t\t\tdpkg-scanpackages . \u003e Packages; \t\t\t\tapt-get -o Acquire::GzipIndexes=false update; \t\t\t}; \t\t\t_update_repo; \t\t\t\t\t\tnproc=\"$(nproc)\"; \t\t\texport DEB_BUILD_OPTIONS=\"nocheck parallel=$nproc\"; \t\t\tapt-get build-dep -y postgresql-common pgdg-keyring; \t\t\tapt-get source --compile postgresql-common pgdg-keyring; \t\t\t_update_repo; \t\t\tapt-get build-dep -y \"postgresql-$PG_MAJOR=$PG_VERSION\"; \t\t\tapt-get source --compile \"postgresql-$PG_MAJOR=$PG_VERSION\"; \t\t\t\t\t\t\t\t\tapt-mark showmanual | xargs apt-mark auto \u003e /dev/null; \t\t\tapt-mark manual $savedAptMark; \t\t\t\t\t\tls -lAFh; \t\t\t_update_repo; \t\t\tgrep '^Package: ' Packages; \t\t\tcd /; \t\t\t;; \tesac; \t\tapt-get install -y --no-install-recommends postgresql-common; \tsed -ri 's/#(create_main_cluster) .*$/\\1 = false/' /etc/postgresql-common/createcluster.conf; \tapt-get install -y --no-install-recommends \t\t\"postgresql-$PG_MAJOR=$PG_VERSION\" \t; \t\trm -rf /var/lib/apt/lists/*; \t\tif [ -n \"$tempDir\" ]; then \t\tapt-get purge -y --auto-remove; \t\trm -rf \"$tempDir\" /etc/apt/sources.list.d/temp.list; \tfi; \t\tfind /usr -name '*.pyc' -type f -exec bash -c 'for pyc; do dpkg -S \"$pyc\" \u0026\u003e /dev/null || rm -vf \"$pyc\"; done' -- '{}' +; \t\tpostgres --version # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2024-05-09T18:58:11Z","created_by":"RUN /bin/sh -c set -eux; \tdpkg-divert --add --rename --divert \"/usr/share/postgresql/postgresql.conf.sample.dpkg\" \"/usr/share/postgresql/$PG_MAJOR/postgresql.conf.sample\"; \tcp -v /usr/share/postgresql/postgresql.conf.sample.dpkg /usr/share/postgresql/postgresql.conf.sample; \tln -sv ../postgresql.conf.sample \"/usr/share/postgresql/$PG_MAJOR/\"; \tsed -ri \"s!^#?(listen_addresses)\\s*=\\s*\\S+.*!\\1 = '*'!\" /usr/share/postgresql/postgresql.conf.sample; \tgrep -F \"listen_addresses = '*'\" /usr/share/postgresql/postgresql.conf.sample # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2024-05-09T18:58:11Z","created_by":"RUN /bin/sh -c mkdir -p /var/run/postgresql \u0026\u0026 chown -R postgres:postgres /var/run/postgresql \u0026\u0026 chmod 3777 /var/run/postgresql # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2024-05-09T18:58:11Z","created_by":"ENV PGDATA=/var/lib/postgresql/data","comment":"buildkit.dockerfile.v0","empty_layer":true},{"created":"2024-05-09T18:58:11Z","created_by":"RUN /bin/sh -c mkdir -p \"$PGDATA\" \u0026\u0026 chown -R postgres:postgres \"$PGDATA\" \u0026\u0026 chmod 1777 \"$PGDATA\" # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2024-05-09T18:58:11Z","created_by":"VOLUME [/var/lib/postgresql/data]","comment":"buildkit.dockerfile.v0","empty_layer":true},{"created":"2024-05-09T18:58:11Z","created_by":"COPY docker-entrypoint.sh docker-ensure-initdb.sh /usr/local/bin/ # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2024-05-09T18:58:11Z","created_by":"RUN /bin/sh -c ln -sT docker-ensure-initdb.sh /usr/local/bin/docker-enforce-initdb.sh # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2024-05-09T18:58:11Z","created_by":"ENTRYPOINT [\"docker-entrypoint.sh\"]","comment":"buildkit.dockerfile.v0","empty_layer":true},{"created":"2024-05-09T18:58:11Z","created_by":"STOPSIGNAL SIGINT","comment":"buildkit.dockerfile.v0","empty_layer":true},{"created":"2024-05-09T18:58:11Z","created_by":"EXPOSE map[5432/tcp:{}]","comment":"buildkit.dockerfile.v0","empty_layer":true},{"created":"2024-05-09T18:58:11Z","created_by":"CMD [\"postgres\"]","comment":"buildkit.dockerfile.v0","empty_layer":true}],"os":"linux","rootfs":{"type":"layers","diff_ids":["sha256:6f697f52d48595d9c5c3104e2ed3d8e617cb437b485e7396ad5f00726125e52b","sha256:9ec058f64b03dc39a8025b7bb19df97528e759056ddfb8451b843674795a0298","sha256:b7ce20ae79b122f64222464ed7fa6996b2fa428a9addb8291601f8380b2714c3","sha256:fad4dcbf20294af96a2ecf85472b997c1ab73f3e6163cb93a11630e9c0d093d0","sha256:a76d1ce375fe1c9d641341004d192ff68a03ff21650cca03f326231b8e586944","sha256:276d9d4f81dd2645f591d95096117fbb451e1e6387bc6d5921e95f2010cafa98","sha256:dcdccebceb325fe84ffd70ece65f888e46fe859afd69e9372b15db3906fafd1c","sha256:41be7ccfd1433dc81a31fd5e8525a73a91f7bbe1af6b18c83daf448c8920824e","sha256:769f0c08a78a6a606365a69b9b3f79ad4e582343deb83af5df8ae6fb53cb4c98","sha256:240e43c985373b4245f872dbd0ab3d75ee12e6725fbe55a54ef5c4346d0e6adf","sha256:2202ada9290d7e64d6f7527574f989f6957a59d789f819c633f69d5ea2a1f97b","sha256:efb6f0a17382fe7d26fd56deae1bcc5b2b3e67f2a4e1ffe599fdeeb3a5cbdb9f","sha256:f4ddf6574562afb84cb9d3a6d76eb58707372b837b03e1e6e5ca56a98f77e54f","sha256:1a6e7ab8c59f87d43486f0930340dbd735530e0849c43aafdd5befde82f19c96"]},"config":{"Cmd":["postgres"],"Entrypoint":["docker-entrypoint.sh"],"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/lib/postgresql/16/bin","GOSU_VERSION=1.17","LANG=en_US.utf8","PG_MAJOR=16","PG_VERSION=16.3-1.pgdg110+1","PGDATA=/var/lib/postgresql/data"],"Volumes":{"/var/lib/postgresql/data":{}},"ExposedPorts":{"5432/tcp":{}},"ArgsEscaped":true,"StopSignal":"SIGINT"}}
    ;

    const parsed = try std.json.parseFromSlice(ConfigFile, testing.allocator, json_string, .{});
    defer parsed.deinit();
    const config_file = parsed.value;
    try testing.expectEqualStrings(config_file.architecture, "amd64");
    try testing.expectEqualStrings(config_file.os, "linux");
    try testing.expect(config_file.history.?.len == 26);
    try testing.expect(config_file.config.?.Env.?.len == 6);
    try testing.expectEqualStrings(config_file.config.?.Cmd.?[0], "postgres");
    try testing.expectEqualStrings(config_file.config.?.StopSignal.?, "SIGINT");
}
