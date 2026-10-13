-- The part of the fingerprint database fpstore reads, as acoustid-server's
-- migrations create it, for tests. acoustid-server owns the real schema.

CREATE EXTENSION IF NOT EXISTS acoustid;

CREATE TABLE fingerprint (
    id serial PRIMARY KEY,
    fingerprint integer[] NOT NULL,
    length smallint NOT NULL CHECK (length > 0),
    bitrate smallint CHECK (bitrate > 0),
    format_id integer,
    created timestamp with time zone NOT NULL DEFAULT current_timestamp,
    updated timestamp with time zone,
    track_id integer NOT NULL,
    submission_count integer NOT NULL
);

CREATE SEQUENCE fpindex_changelog_id_seq AS bigint;

CREATE TABLE fpindex_changelog (
    id bigint NOT NULL DEFAULT nextval('fpindex_changelog_id_seq'),
    fingerprint_id integer NOT NULL,
    query integer[] NOT NULL,
    xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    created timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fpindex_changelog_pkey PRIMARY KEY (id, created)
) PARTITION BY RANGE (created);

ALTER SEQUENCE fpindex_changelog_id_seq OWNED BY fpindex_changelog.id;

-- Last month, for tests of retention, this one and the next.
DO $$
DECLARE
    start_month date := (date_trunc('month', current_date) - interval '1 month')::date;
    part_month date;
BEGIN
    FOR offset_months IN 0..2 LOOP
        part_month := (start_month + (offset_months || ' months')::interval)::date;
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF fpindex_changelog FOR VALUES FROM (%L) TO (%L)',
            'fpindex_changelog_' || to_char(part_month, 'YYYYMM'),
            part_month,
            (part_month + interval '1 month')::date
        );
    END LOOP;
END
$$;

CREATE FUNCTION fpindex_changelog_insert() RETURNS trigger AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(7723016524936704001);
    INSERT INTO fpindex_changelog (fingerprint_id, query)
        VALUES (NEW.id, acoustid_extract_query(NEW.fingerprint));
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER fingerprint_fpindex_changelog
    AFTER INSERT ON fingerprint
    FOR EACH ROW
    EXECUTE FUNCTION fpindex_changelog_insert();

CREATE TABLE fpindex_meta (
    singleton boolean NOT NULL DEFAULT true,
    last_deleted_id bigint NOT NULL,
    last_deleted_created timestamp with time zone NOT NULL,
    last_deleted_xid xid8 NOT NULL,
    updated timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fpindex_meta_pkey PRIMARY KEY (singleton),
    CONSTRAINT fpindex_meta_singleton CHECK (singleton)
);
