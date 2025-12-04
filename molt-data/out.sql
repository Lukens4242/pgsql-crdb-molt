-- Note: this file has the original DDL annotated.
-- Edit this file and address all the errors.
-- Review the warnings and confirm the statement conversion.
-- Tip:
--   to find all the errors search for "-- error: "
--   to find all the warnings search for "-- warning: "


-- Summary:
--  Total Statements: 23
--  Successful Statements: 23
--  Failed Statements: 0
--  Deleted Statements: 0
--  Warnings: 0
--  Suggestions: 2
--  Other Errors: 0
--  SQL Errors: 0
--  Not Implemented: 0





-- statement: 1
-- status: pending
-- attempt: 
-- SET statement_timeout = 0
-- original:
SET statement_timeout = 0;

    
-- statement: 2
-- status: pending
-- attempt: 
-- SET lock_timeout = 0
-- original:
SET lock_timeout = 0;

    
-- statement: 3
-- status: pending
-- attempt: 
-- SET idle_in_transaction_session_timeout = 0
-- original:
SET idle_in_transaction_session_timeout = 0;

    
-- statement: 4
-- status: pending
-- attempt: 
-- SET transaction_timeout = 0
-- original:
SET transaction_timeout = 0;

    
-- statement: 5
-- status: pending
-- attempt: 
-- SET client_encoding = 'UTF8'
-- original:
SET client_encoding = 'UTF8';

    
-- statement: 6
-- status: pending
-- attempt: 
-- SET standard_conforming_strings = "on"
-- original:
SET standard_conforming_strings = on;

    
-- statement: 7
-- status: pending
-- attempt: 
-- SELECT pg_catalog.set_config('search_path', '', false)
-- original:
SELECT pg_catalog.set_config('search_path', '', false);

    
-- statement: 8
-- status: pending
-- attempt: 
-- SET check_function_bodies = false
-- original:
SET check_function_bodies = false;

    
-- statement: 9
-- status: pending
-- attempt: 
-- SET xmloption = content
-- original:
SET xmloption = content;

    
-- statement: 10
-- status: pending
-- attempt: 
-- SET client_min_messages = warning
-- original:
SET client_min_messages = warning;

    
-- statement: 11
-- status: pending
-- attempt: 
-- SET row_security = off
-- original:
SET row_security = off;

    
-- statement: 12
-- status: pending
-- attempt: 
-- CREATE TYPE public.user_role AS ENUM ('admin', 'editor', 'viewer')
-- original:
CREATE TYPE public.user_role AS ENUM (
    'admin',
    'editor',
    'viewer'
);

    
-- statement: 13
-- status: pending
-- attempt: 
-- ALTER TYPE public.user_role OWNER TO admin
-- original:
ALTER TYPE public.user_role OWNER TO admin;

    
-- statement: 14
-- status: pending
-- attempt: 
-- SET default_tablespace = ''
-- original:
SET default_tablespace = '';

    
-- statement: 15
-- status: pending
-- attempt: 
-- SET default_table_access_method = heap
-- original:
SET default_table_access_method = heap;

    
-- statement: 16
-- status: pending
-- attempt: 
-- CREATE TABLE public.users (
-- 	id INT4 NOT NULL,
-- 	name STRING NOT NULL,
-- 	email STRING NOT NULL,
-- 	"role" public.user_role
-- 	DEFAULT 'viewer'::public.user_role
-- 	NOT NULL,
-- 	CONSTRAINT users_pkey PRIMARY KEY (id)
-- )
-- original:
CREATE TABLE public.users (
    id integer NOT NULL,
    name text NOT NULL,
    email text NOT NULL,
    role public.user_role DEFAULT 'viewer'::public.user_role NOT NULL
);

    
-- statement: 17
-- status: pending
-- attempt: 
-- ALTER TABLE public.users OWNER TO admin
-- original:
ALTER TABLE public.users OWNER TO admin;

    
-- statement: 18
-- status: pending
-- suggestion: We recommend auto-generating unique IDs instead of using a sequence. For more details, see: https://www.cockroachlabs.com/docs/stable/create-sequence.html#considerations

-- attempt: 
-- CREATE SEQUENCE public.users_id_seq AS INT4 START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1
-- original:
CREATE SEQUENCE public.users_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

    
-- statement: 19
-- status: pending
-- attempt: 
-- ALTER SEQUENCE public.users_id_seq OWNER TO admin
-- original:
ALTER SEQUENCE public.users_id_seq OWNER TO admin;

    
-- statement: 20
-- status: pending
-- attempt: 
-- ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id
-- original:
ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;

    
-- statement: 21
-- status: pending
-- suggestion: Column id utilizes a sequence. We recommend auto-generating unique IDs instead of using a sequence. For more details, see: https://www.cockroachlabs.com/docs/stable/create-sequence.html#considerations
-- attempt: 
-- ALTER TABLE public.users
-- 	ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::REGCLASS)
-- original:
ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);

    
-- statement: 22
-- status: pending
-- attempt: 
-- ALTER TABLE public.users
-- 	ADD CONSTRAINT users_email_key UNIQUE (email)
-- original:
ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);

    
-- statement: 23
-- status: combined
-- attempt: 
-- 
-- original:
ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);

    
