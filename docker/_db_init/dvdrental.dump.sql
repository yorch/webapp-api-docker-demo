--
-- PostgreSQL database dump
--

-- Dumped from database version 12.2 (Debian 12.2-1.pgdg100+1)
-- Dumped by pg_dump version 12.2 (Debian 12.2-1.pgdg100+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: mpaa_rating; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.mpaa_rating AS ENUM (
    'G',
    'PG',
    'PG-13',
    'R',
    'NC-17'
);


ALTER TYPE public.mpaa_rating OWNER TO postgres;

--
-- Name: year; Type: DOMAIN; Schema: public; Owner: postgres
--

CREATE DOMAIN public.year AS integer
	CONSTRAINT year_check CHECK (((VALUE >= 1901) AND (VALUE <= 2155)));


ALTER DOMAIN public.year OWNER TO postgres;

--
-- Name: _group_concat(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public._group_concat(text, text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $_$
SELECT CASE
  WHEN $2 IS NULL THEN $1
  WHEN $1 IS NULL THEN $2
  ELSE $1 || ', ' || $2
END
$_$;


ALTER FUNCTION public._group_concat(text, text) OWNER TO postgres;

--
-- Name: film_in_stock(integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.film_in_stock(p_film_id integer, p_store_id integer, OUT p_film_count integer) RETURNS SETOF integer
    LANGUAGE sql
    AS $_$
     SELECT inventory_id
     FROM inventory
     WHERE film_id = $1
     AND store_id = $2
     AND inventory_in_stock(inventory_id);
$_$;


ALTER FUNCTION public.film_in_stock(p_film_id integer, p_store_id integer, OUT p_film_count integer) OWNER TO postgres;

--
-- Name: film_not_in_stock(integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.film_not_in_stock(p_film_id integer, p_store_id integer, OUT p_film_count integer) RETURNS SETOF integer
    LANGUAGE sql
    AS $_$
    SELECT inventory_id
    FROM inventory
    WHERE film_id = $1
    AND store_id = $2
    AND NOT inventory_in_stock(inventory_id);
$_$;


ALTER FUNCTION public.film_not_in_stock(p_film_id integer, p_store_id integer, OUT p_film_count integer) OWNER TO postgres;

--
-- Name: get_customer_balance(integer, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_customer_balance(p_customer_id integer, p_effective_date timestamp without time zone) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
       --#OK, WE NEED TO CALCULATE THE CURRENT BALANCE GIVEN A CUSTOMER_ID AND A DATE
       --#THAT WE WANT THE BALANCE TO BE EFFECTIVE FOR. THE BALANCE IS:
       --#   1) RENTAL FEES FOR ALL PREVIOUS RENTALS
       --#   2) ONE DOLLAR FOR EVERY DAY THE PREVIOUS RENTALS ARE OVERDUE
       --#   3) IF A FILM IS MORE THAN RENTAL_DURATION * 2 OVERDUE, CHARGE THE REPLACEMENT_COST
       --#   4) SUBTRACT ALL PAYMENTS MADE BEFORE THE DATE SPECIFIED
DECLARE
    v_rentfees DECIMAL(5,2); --#FEES PAID TO RENT THE VIDEOS INITIALLY
    v_overfees INTEGER;      --#LATE FEES FOR PRIOR RENTALS
    v_payments DECIMAL(5,2); --#SUM OF PAYMENTS MADE PREVIOUSLY
BEGIN
    SELECT COALESCE(SUM(film.rental_rate),0) INTO v_rentfees
    FROM film, inventory, rental
    WHERE film.film_id = inventory.film_id
      AND inventory.inventory_id = rental.inventory_id
      AND rental.rental_date <= p_effective_date
      AND rental.customer_id = p_customer_id;

    SELECT COALESCE(SUM(CASE WHEN (rental.return_date - rental.rental_date) > (film.rental_duration * '1 day'::interval)
        THEN EXTRACT(DAY FROM (rental.return_date - rental.rental_date) - (film.rental_duration * '1 day'::interval))::integer
        ELSE 0 END),0) INTO v_overfees
    FROM rental, inventory, film
    WHERE film.film_id = inventory.film_id
      AND inventory.inventory_id = rental.inventory_id
      AND rental.rental_date <= p_effective_date
      AND rental.customer_id = p_customer_id;

    SELECT COALESCE(SUM(payment.amount),0) INTO v_payments
    FROM payment
    WHERE payment.payment_date <= p_effective_date
    AND payment.customer_id = p_customer_id;

    RETURN v_rentfees + v_overfees - v_payments;
END
$$;


ALTER FUNCTION public.get_customer_balance(p_customer_id integer, p_effective_date timestamp without time zone) OWNER TO postgres;

--
-- Name: inventory_held_by_customer(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.inventory_held_by_customer(p_inventory_id integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_customer_id INTEGER;
BEGIN

  SELECT customer_id INTO v_customer_id
  FROM rental
  WHERE return_date IS NULL
  AND inventory_id = p_inventory_id;

  RETURN v_customer_id;
END $$;


ALTER FUNCTION public.inventory_held_by_customer(p_inventory_id integer) OWNER TO postgres;

--
-- Name: inventory_in_stock(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.inventory_in_stock(p_inventory_id integer) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_rentals INTEGER;
    v_out     INTEGER;
BEGIN
    -- AN ITEM IS IN-STOCK IF THERE ARE EITHER NO ROWS IN THE rental TABLE
    -- FOR THE ITEM OR ALL ROWS HAVE return_date POPULATED

    SELECT count(*) INTO v_rentals
    FROM rental
    WHERE inventory_id = p_inventory_id;

    IF v_rentals = 0 THEN
      RETURN TRUE;
    END IF;

    SELECT COUNT(rental_id) INTO v_out
    FROM inventory LEFT JOIN rental USING(inventory_id)
    WHERE inventory.inventory_id = p_inventory_id
    AND rental.return_date IS NULL;

    IF v_out > 0 THEN
      RETURN FALSE;
    ELSE
      RETURN TRUE;
    END IF;
END $$;


ALTER FUNCTION public.inventory_in_stock(p_inventory_id integer) OWNER TO postgres;

--
-- Name: last_day(timestamp without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.last_day(timestamp without time zone) RETURNS date
    LANGUAGE sql IMMUTABLE STRICT
    AS $_$
  SELECT CASE
    WHEN EXTRACT(MONTH FROM $1) = 12 THEN
      (((EXTRACT(YEAR FROM $1) + 1) operator(pg_catalog.||) '-01-01')::date - INTERVAL '1 day')::date
    ELSE
      ((EXTRACT(YEAR FROM $1) operator(pg_catalog.||) '-' operator(pg_catalog.||) (EXTRACT(MONTH FROM $1) + 1) operator(pg_catalog.||) '-01')::date - INTERVAL '1 day')::date
    END
$_$;


ALTER FUNCTION public.last_day(timestamp without time zone) OWNER TO postgres;

--
-- Name: last_updated(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.last_updated() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.last_update = CURRENT_TIMESTAMP;
    RETURN NEW;
END $$;


ALTER FUNCTION public.last_updated() OWNER TO postgres;

--
-- Name: customer_customer_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.customer_customer_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.customer_customer_id_seq OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: customer; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.customer (
    customer_id integer DEFAULT nextval('public.customer_customer_id_seq'::regclass) NOT NULL,
    store_id smallint NOT NULL,
    first_name character varying(45) NOT NULL,
    last_name character varying(45) NOT NULL,
    email character varying(50),
    address_id smallint NOT NULL,
    activebool boolean DEFAULT true NOT NULL,
    create_date date DEFAULT ('now'::text)::date NOT NULL,
    last_update timestamp without time zone DEFAULT now(),
    active integer
);


ALTER TABLE public.customer OWNER TO postgres;

--
-- Name: rewards_report(integer, numeric); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rewards_report(min_monthly_purchases integer, min_dollar_amount_purchased numeric) RETURNS SETOF public.customer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $_$
DECLARE
    last_month_start DATE;
    last_month_end DATE;
rr RECORD;
tmpSQL TEXT;
BEGIN

    /* Some sanity checks... */
    IF min_monthly_purchases = 0 THEN
        RAISE EXCEPTION 'Minimum monthly purchases parameter must be > 0';
    END IF;
    IF min_dollar_amount_purchased = 0.00 THEN
        RAISE EXCEPTION 'Minimum monthly dollar amount purchased parameter must be > $0.00';
    END IF;

    last_month_start := CURRENT_DATE - '3 month'::interval;
    last_month_start := to_date((extract(YEAR FROM last_month_start) || '-' || extract(MONTH FROM last_month_start) || '-01'),'YYYY-MM-DD');
    last_month_end := LAST_DAY(last_month_start);

    /*
    Create a temporary storage area for Customer IDs.
    */
    CREATE TEMPORARY TABLE tmpCustomer (customer_id INTEGER NOT NULL PRIMARY KEY);

    /*
    Find all customers meeting the monthly purchase requirements
    */

    tmpSQL := 'INSERT INTO tmpCustomer (customer_id)
        SELECT p.customer_id
        FROM payment AS p
        WHERE DATE(p.payment_date) BETWEEN '||quote_literal(last_month_start) ||' AND '|| quote_literal(last_month_end) || '
        GROUP BY customer_id
        HAVING SUM(p.amount) > '|| min_dollar_amount_purchased || '
        AND COUNT(customer_id) > ' ||min_monthly_purchases ;

    EXECUTE tmpSQL;

    /*
    Output ALL customer information of matching rewardees.
    Customize output as needed.
    */
    FOR rr IN EXECUTE 'SELECT c.* FROM tmpCustomer AS t INNER JOIN customer AS c ON t.customer_id = c.customer_id' LOOP
        RETURN NEXT rr;
    END LOOP;

    /* Clean up */
    tmpSQL := 'DROP TABLE tmpCustomer';
    EXECUTE tmpSQL;

RETURN;
END
$_$;


ALTER FUNCTION public.rewards_report(min_monthly_purchases integer, min_dollar_amount_purchased numeric) OWNER TO postgres;

--
-- Name: group_concat(text); Type: AGGREGATE; Schema: public; Owner: postgres
--

CREATE AGGREGATE public.group_concat(text) (
    SFUNC = public._group_concat,
    STYPE = text
);


ALTER AGGREGATE public.group_concat(text) OWNER TO postgres;

--
-- Name: actor_actor_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.actor_actor_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.actor_actor_id_seq OWNER TO postgres;

--
-- Name: actor; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.actor (
    actor_id integer DEFAULT nextval('public.actor_actor_id_seq'::regclass) NOT NULL,
    first_name character varying(45) NOT NULL,
    last_name character varying(45) NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.actor OWNER TO postgres;

--
-- Name: category_category_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.category_category_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.category_category_id_seq OWNER TO postgres;

--
-- Name: category; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.category (
    category_id integer DEFAULT nextval('public.category_category_id_seq'::regclass) NOT NULL,
    name character varying(25) NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.category OWNER TO postgres;

--
-- Name: film_film_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.film_film_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.film_film_id_seq OWNER TO postgres;

--
-- Name: film; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.film (
    film_id integer DEFAULT nextval('public.film_film_id_seq'::regclass) NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    release_year public.year,
    language_id smallint NOT NULL,
    original_language_id smallint,
    rental_duration smallint DEFAULT 3 NOT NULL,
    rental_rate numeric(4,2) DEFAULT 4.99 NOT NULL,
    length smallint,
    replacement_cost numeric(5,2) DEFAULT 19.99 NOT NULL,
    rating public.mpaa_rating DEFAULT 'G'::public.mpaa_rating,
    last_update timestamp without time zone DEFAULT now() NOT NULL,
    special_features text[],
    fulltext tsvector NOT NULL
);


ALTER TABLE public.film OWNER TO postgres;

--
-- Name: film_actor; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.film_actor (
    actor_id smallint NOT NULL,
    film_id smallint NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.film_actor OWNER TO postgres;

--
-- Name: film_category; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.film_category (
    film_id smallint NOT NULL,
    category_id smallint NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.film_category OWNER TO postgres;

--
-- Name: actor_info; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.actor_info AS
 SELECT a.actor_id,
    a.first_name,
    a.last_name,
    public.group_concat(DISTINCT (((c.name)::text || ': '::text) || ( SELECT public.group_concat((f.title)::text) AS group_concat
           FROM ((public.film f
             JOIN public.film_category fc_1 ON ((f.film_id = fc_1.film_id)))
             JOIN public.film_actor fa_1 ON ((f.film_id = fa_1.film_id)))
          WHERE ((fc_1.category_id = c.category_id) AND (fa_1.actor_id = a.actor_id))
          GROUP BY fa_1.actor_id))) AS film_info
   FROM (((public.actor a
     LEFT JOIN public.film_actor fa ON ((a.actor_id = fa.actor_id)))
     LEFT JOIN public.film_category fc ON ((fa.film_id = fc.film_id)))
     LEFT JOIN public.category c ON ((fc.category_id = c.category_id)))
  GROUP BY a.actor_id, a.first_name, a.last_name;


ALTER TABLE public.actor_info OWNER TO postgres;

--
-- Name: address_address_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.address_address_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.address_address_id_seq OWNER TO postgres;

--
-- Name: address; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.address (
    address_id integer DEFAULT nextval('public.address_address_id_seq'::regclass) NOT NULL,
    address character varying(50) NOT NULL,
    address2 character varying(50),
    district character varying(20) NOT NULL,
    city_id smallint NOT NULL,
    postal_code character varying(10),
    phone character varying(20) NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.address OWNER TO postgres;

--
-- Name: city_city_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.city_city_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.city_city_id_seq OWNER TO postgres;

--
-- Name: city; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.city (
    city_id integer DEFAULT nextval('public.city_city_id_seq'::regclass) NOT NULL,
    city character varying(50) NOT NULL,
    country_id smallint NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.city OWNER TO postgres;

--
-- Name: country_country_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.country_country_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.country_country_id_seq OWNER TO postgres;

--
-- Name: country; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.country (
    country_id integer DEFAULT nextval('public.country_country_id_seq'::regclass) NOT NULL,
    country character varying(50) NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.country OWNER TO postgres;

--
-- Name: customer_list; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.customer_list AS
 SELECT cu.customer_id AS id,
    (((cu.first_name)::text || ' '::text) || (cu.last_name)::text) AS name,
    a.address,
    a.postal_code AS "zip code",
    a.phone,
    city.city,
    country.country,
        CASE
            WHEN cu.activebool THEN 'active'::text
            ELSE ''::text
        END AS notes,
    cu.store_id AS sid
   FROM (((public.customer cu
     JOIN public.address a ON ((cu.address_id = a.address_id)))
     JOIN public.city ON ((a.city_id = city.city_id)))
     JOIN public.country ON ((city.country_id = country.country_id)));


ALTER TABLE public.customer_list OWNER TO postgres;

--
-- Name: film_list; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.film_list AS
 SELECT film.film_id AS fid,
    film.title,
    film.description,
    category.name AS category,
    film.rental_rate AS price,
    film.length,
    film.rating,
    public.group_concat((((actor.first_name)::text || ' '::text) || (actor.last_name)::text)) AS actors
   FROM ((((public.category
     LEFT JOIN public.film_category ON ((category.category_id = film_category.category_id)))
     LEFT JOIN public.film ON ((film_category.film_id = film.film_id)))
     JOIN public.film_actor ON ((film.film_id = film_actor.film_id)))
     JOIN public.actor ON ((film_actor.actor_id = actor.actor_id)))
  GROUP BY film.film_id, film.title, film.description, category.name, film.rental_rate, film.length, film.rating;


ALTER TABLE public.film_list OWNER TO postgres;

--
-- Name: inventory_inventory_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.inventory_inventory_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.inventory_inventory_id_seq OWNER TO postgres;

--
-- Name: inventory; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.inventory (
    inventory_id integer DEFAULT nextval('public.inventory_inventory_id_seq'::regclass) NOT NULL,
    film_id smallint NOT NULL,
    store_id smallint NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.inventory OWNER TO postgres;

--
-- Name: language_language_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.language_language_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.language_language_id_seq OWNER TO postgres;

--
-- Name: language; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.language (
    language_id integer DEFAULT nextval('public.language_language_id_seq'::regclass) NOT NULL,
    name character(20) NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.language OWNER TO postgres;

--
-- Name: nicer_but_slower_film_list; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.nicer_but_slower_film_list AS
 SELECT film.film_id AS fid,
    film.title,
    film.description,
    category.name AS category,
    film.rental_rate AS price,
    film.length,
    film.rating,
    public.group_concat((((upper("substring"((actor.first_name)::text, 1, 1)) || lower("substring"((actor.first_name)::text, 2))) || upper("substring"((actor.last_name)::text, 1, 1))) || lower("substring"((actor.last_name)::text, 2)))) AS actors
   FROM ((((public.category
     LEFT JOIN public.film_category ON ((category.category_id = film_category.category_id)))
     LEFT JOIN public.film ON ((film_category.film_id = film.film_id)))
     JOIN public.film_actor ON ((film.film_id = film_actor.film_id)))
     JOIN public.actor ON ((film_actor.actor_id = actor.actor_id)))
  GROUP BY film.film_id, film.title, film.description, category.name, film.rental_rate, film.length, film.rating;


ALTER TABLE public.nicer_but_slower_film_list OWNER TO postgres;

--
-- Name: payment_payment_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.payment_payment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.payment_payment_id_seq OWNER TO postgres;

--
-- Name: payment; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payment (
    payment_id integer DEFAULT nextval('public.payment_payment_id_seq'::regclass) NOT NULL,
    customer_id smallint NOT NULL,
    staff_id smallint NOT NULL,
    rental_id integer NOT NULL,
    amount numeric(5,2) NOT NULL,
    payment_date timestamp without time zone NOT NULL
);


ALTER TABLE public.payment OWNER TO postgres;

--
-- Name: payment_p2007_01; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payment_p2007_01 (
    CONSTRAINT payment_p2007_01_payment_date_check CHECK (((payment_date >= '2007-01-01 00:00:00'::timestamp without time zone) AND (payment_date < '2007-02-01 00:00:00'::timestamp without time zone)))
)
INHERITS (public.payment);


ALTER TABLE public.payment_p2007_01 OWNER TO postgres;

--
-- Name: payment_p2007_02; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payment_p2007_02 (
    CONSTRAINT payment_p2007_02_payment_date_check CHECK (((payment_date >= '2007-02-01 00:00:00'::timestamp without time zone) AND (payment_date < '2007-03-01 00:00:00'::timestamp without time zone)))
)
INHERITS (public.payment);


ALTER TABLE public.payment_p2007_02 OWNER TO postgres;

--
-- Name: payment_p2007_03; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payment_p2007_03 (
    CONSTRAINT payment_p2007_03_payment_date_check CHECK (((payment_date >= '2007-03-01 00:00:00'::timestamp without time zone) AND (payment_date < '2007-04-01 00:00:00'::timestamp without time zone)))
)
INHERITS (public.payment);


ALTER TABLE public.payment_p2007_03 OWNER TO postgres;

--
-- Name: payment_p2007_04; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payment_p2007_04 (
    CONSTRAINT payment_p2007_04_payment_date_check CHECK (((payment_date >= '2007-04-01 00:00:00'::timestamp without time zone) AND (payment_date < '2007-05-01 00:00:00'::timestamp without time zone)))
)
INHERITS (public.payment);


ALTER TABLE public.payment_p2007_04 OWNER TO postgres;

--
-- Name: payment_p2007_05; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payment_p2007_05 (
    CONSTRAINT payment_p2007_05_payment_date_check CHECK (((payment_date >= '2007-05-01 00:00:00'::timestamp without time zone) AND (payment_date < '2007-06-01 00:00:00'::timestamp without time zone)))
)
INHERITS (public.payment);


ALTER TABLE public.payment_p2007_05 OWNER TO postgres;

--
-- Name: payment_p2007_06; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payment_p2007_06 (
    CONSTRAINT payment_p2007_06_payment_date_check CHECK (((payment_date >= '2007-06-01 00:00:00'::timestamp without time zone) AND (payment_date < '2007-07-01 00:00:00'::timestamp without time zone)))
)
INHERITS (public.payment);


ALTER TABLE public.payment_p2007_06 OWNER TO postgres;

--
-- Name: rental_rental_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.rental_rental_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.rental_rental_id_seq OWNER TO postgres;

--
-- Name: rental; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.rental (
    rental_id integer DEFAULT nextval('public.rental_rental_id_seq'::regclass) NOT NULL,
    rental_date timestamp without time zone NOT NULL,
    inventory_id integer NOT NULL,
    customer_id smallint NOT NULL,
    return_date timestamp without time zone,
    staff_id smallint NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.rental OWNER TO postgres;

--
-- Name: sales_by_film_category; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.sales_by_film_category AS
 SELECT c.name AS category,
    sum(p.amount) AS total_sales
   FROM (((((public.payment p
     JOIN public.rental r ON ((p.rental_id = r.rental_id)))
     JOIN public.inventory i ON ((r.inventory_id = i.inventory_id)))
     JOIN public.film f ON ((i.film_id = f.film_id)))
     JOIN public.film_category fc ON ((f.film_id = fc.film_id)))
     JOIN public.category c ON ((fc.category_id = c.category_id)))
  GROUP BY c.name
  ORDER BY (sum(p.amount)) DESC;


ALTER TABLE public.sales_by_film_category OWNER TO postgres;

--
-- Name: staff_staff_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.staff_staff_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.staff_staff_id_seq OWNER TO postgres;

--
-- Name: staff; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.staff (
    staff_id integer DEFAULT nextval('public.staff_staff_id_seq'::regclass) NOT NULL,
    first_name character varying(45) NOT NULL,
    last_name character varying(45) NOT NULL,
    address_id smallint NOT NULL,
    email character varying(50),
    store_id smallint NOT NULL,
    active boolean DEFAULT true NOT NULL,
    username character varying(16) NOT NULL,
    password character varying(40),
    last_update timestamp without time zone DEFAULT now() NOT NULL,
    picture bytea
);


ALTER TABLE public.staff OWNER TO postgres;

--
-- Name: store_store_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.store_store_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.store_store_id_seq OWNER TO postgres;

--
-- Name: store; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.store (
    store_id integer DEFAULT nextval('public.store_store_id_seq'::regclass) NOT NULL,
    manager_staff_id smallint NOT NULL,
    address_id smallint NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.store OWNER TO postgres;

--
-- Name: sales_by_store; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.sales_by_store AS
 SELECT (((c.city)::text || ','::text) || (cy.country)::text) AS store,
    (((m.first_name)::text || ' '::text) || (m.last_name)::text) AS manager,
    sum(p.amount) AS total_sales
   FROM (((((((public.payment p
     JOIN public.rental r ON ((p.rental_id = r.rental_id)))
     JOIN public.inventory i ON ((r.inventory_id = i.inventory_id)))
     JOIN public.store s ON ((i.store_id = s.store_id)))
     JOIN public.address a ON ((s.address_id = a.address_id)))
     JOIN public.city c ON ((a.city_id = c.city_id)))
     JOIN public.country cy ON ((c.country_id = cy.country_id)))
     JOIN public.staff m ON ((s.manager_staff_id = m.staff_id)))
  GROUP BY cy.country, c.city, s.store_id, m.first_name, m.last_name
  ORDER BY cy.country, c.city;


ALTER TABLE public.sales_by_store OWNER TO postgres;

--
-- Name: staff_list; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.staff_list AS
 SELECT s.staff_id AS id,
    (((s.first_name)::text || ' '::text) || (s.last_name)::text) AS name,
    a.address,
    a.postal_code AS "zip code",
    a.phone,
    city.city,
    country.country,
    s.store_id AS sid
   FROM (((public.staff s
     JOIN public.address a ON ((s.address_id = a.address_id)))
     JOIN public.city ON ((a.city_id = city.city_id)))
     JOIN public.country ON ((city.country_id = country.country_id)));


ALTER TABLE public.staff_list OWNER TO postgres;

--
-- Name: payment_p2007_01 payment_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_01 ALTER COLUMN payment_id SET DEFAULT nextval('public.payment_payment_id_seq'::regclass);


--
-- Name: payment_p2007_02 payment_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_02 ALTER COLUMN payment_id SET DEFAULT nextval('public.payment_payment_id_seq'::regclass);


--
-- Name: payment_p2007_03 payment_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_03 ALTER COLUMN payment_id SET DEFAULT nextval('public.payment_payment_id_seq'::regclass);


--
-- Name: payment_p2007_04 payment_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_04 ALTER COLUMN payment_id SET DEFAULT nextval('public.payment_payment_id_seq'::regclass);


--
-- Name: payment_p2007_05 payment_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_05 ALTER COLUMN payment_id SET DEFAULT nextval('public.payment_payment_id_seq'::regclass);


--
-- Name: payment_p2007_06 payment_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_06 ALTER COLUMN payment_id SET DEFAULT nextval('public.payment_payment_id_seq'::regclass);


--
-- Data for Name: actor; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.actor (actor_id, first_name, last_name, last_update) FROM stdin;
1	PENELOPE	GUINESS	2006-02-15 04:34:33
2	NICK	WAHLBERG	2006-02-15 04:34:33
3	ED	CHASE	2006-02-15 04:34:33
4	JENNIFER	DAVIS	2006-02-15 04:34:33
5	JOHNNY	LOLLOBRIGIDA	2006-02-15 04:34:33
6	BETTE	NICHOLSON	2006-02-15 04:34:33
7	GRACE	MOSTEL	2006-02-15 04:34:33
8	MATTHEW	JOHANSSON	2006-02-15 04:34:33
9	JOE	SWANK	2006-02-15 04:34:33
10	CHRISTIAN	GABLE	2006-02-15 04:34:33
11	ZERO	CAGE	2006-02-15 04:34:33
12	KARL	BERRY	2006-02-15 04:34:33
13	UMA	WOOD	2006-02-15 04:34:33
14	VIVIEN	BERGEN	2006-02-15 04:34:33
15	CUBA	OLIVIER	2006-02-15 04:34:33
16	FRED	COSTNER	2006-02-15 04:34:33
17	HELEN	VOIGHT	2006-02-15 04:34:33
18	DAN	TORN	2006-02-15 04:34:33
19	BOB	FAWCETT	2006-02-15 04:34:33
20	LUCILLE	TRACY	2006-02-15 04:34:33
21	KIRSTEN	PALTROW	2006-02-15 04:34:33
22	ELVIS	MARX	2006-02-15 04:34:33
23	SANDRA	KILMER	2006-02-15 04:34:33
24	CAMERON	STREEP	2006-02-15 04:34:33
25	KEVIN	BLOOM	2006-02-15 04:34:33
26	RIP	CRAWFORD	2006-02-15 04:34:33
27	JULIA	MCQUEEN	2006-02-15 04:34:33
28	WOODY	HOFFMAN	2006-02-15 04:34:33
29	ALEC	WAYNE	2006-02-15 04:34:33
30	SANDRA	PECK	2006-02-15 04:34:33
31	SISSY	SOBIESKI	2006-02-15 04:34:33
32	TIM	HACKMAN	2006-02-15 04:34:33
33	MILLA	PECK	2006-02-15 04:34:33
34	AUDREY	OLIVIER	2006-02-15 04:34:33
35	JUDY	DEAN	2006-02-15 04:34:33
36	BURT	DUKAKIS	2006-02-15 04:34:33
37	VAL	BOLGER	2006-02-15 04:34:33
38	TOM	MCKELLEN	2006-02-15 04:34:33
39	GOLDIE	BRODY	2006-02-15 04:34:33
40	JOHNNY	CAGE	2006-02-15 04:34:33
41	JODIE	DEGENERES	2006-02-15 04:34:33
42	TOM	MIRANDA	2006-02-15 04:34:33
43	KIRK	JOVOVICH	2006-02-15 04:34:33
44	NICK	STALLONE	2006-02-15 04:34:33
45	REESE	KILMER	2006-02-15 04:34:33
46	PARKER	GOLDBERG	2006-02-15 04:34:33
47	JULIA	BARRYMORE	2006-02-15 04:34:33
48	FRANCES	DAY-LEWIS	2006-02-15 04:34:33
49	ANNE	CRONYN	2006-02-15 04:34:33
50	NATALIE	HOPKINS	2006-02-15 04:34:33
51	GARY	PHOENIX	2006-02-15 04:34:33
52	CARMEN	HUNT	2006-02-15 04:34:33
53	MENA	TEMPLE	2006-02-15 04:34:33
54	PENELOPE	PINKETT	2006-02-15 04:34:33
55	FAY	KILMER	2006-02-15 04:34:33
56	DAN	HARRIS	2006-02-15 04:34:33
57	JUDE	CRUISE	2006-02-15 04:34:33
58	CHRISTIAN	AKROYD	2006-02-15 04:34:33
59	DUSTIN	TAUTOU	2006-02-15 04:34:33
60	HENRY	BERRY	2006-02-15 04:34:33
61	CHRISTIAN	NEESON	2006-02-15 04:34:33
62	JAYNE	NEESON	2006-02-15 04:34:33
63	CAMERON	WRAY	2006-02-15 04:34:33
64	RAY	JOHANSSON	2006-02-15 04:34:33
65	ANGELA	HUDSON	2006-02-15 04:34:33
66	MARY	TANDY	2006-02-15 04:34:33
67	JESSICA	BAILEY	2006-02-15 04:34:33
68	RIP	WINSLET	2006-02-15 04:34:33
69	KENNETH	PALTROW	2006-02-15 04:34:33
70	MICHELLE	MCCONAUGHEY	2006-02-15 04:34:33
71	ADAM	GRANT	2006-02-15 04:34:33
72	SEAN	WILLIAMS	2006-02-15 04:34:33
73	GARY	PENN	2006-02-15 04:34:33
74	MILLA	KEITEL	2006-02-15 04:34:33
75	BURT	POSEY	2006-02-15 04:34:33
76	ANGELINA	ASTAIRE	2006-02-15 04:34:33
77	CARY	MCCONAUGHEY	2006-02-15 04:34:33
78	GROUCHO	SINATRA	2006-02-15 04:34:33
79	MAE	HOFFMAN	2006-02-15 04:34:33
80	RALPH	CRUZ	2006-02-15 04:34:33
81	SCARLETT	DAMON	2006-02-15 04:34:33
82	WOODY	JOLIE	2006-02-15 04:34:33
83	BEN	WILLIS	2006-02-15 04:34:33
84	JAMES	PITT	2006-02-15 04:34:33
85	MINNIE	ZELLWEGER	2006-02-15 04:34:33
86	GREG	CHAPLIN	2006-02-15 04:34:33
87	SPENCER	PECK	2006-02-15 04:34:33
88	KENNETH	PESCI	2006-02-15 04:34:33
89	CHARLIZE	DENCH	2006-02-15 04:34:33
90	SEAN	GUINESS	2006-02-15 04:34:33
91	CHRISTOPHER	BERRY	2006-02-15 04:34:33
92	KIRSTEN	AKROYD	2006-02-15 04:34:33
93	ELLEN	PRESLEY	2006-02-15 04:34:33
94	KENNETH	TORN	2006-02-15 04:34:33
95	DARYL	WAHLBERG	2006-02-15 04:34:33
96	GENE	WILLIS	2006-02-15 04:34:33
97	MEG	HAWKE	2006-02-15 04:34:33
98	CHRIS	BRIDGES	2006-02-15 04:34:33
99	JIM	MOSTEL	2006-02-15 04:34:33
100	SPENCER	DEPP	2006-02-15 04:34:33
101	SUSAN	DAVIS	2006-02-15 04:34:33
102	WALTER	TORN	2006-02-15 04:34:33
103	MATTHEW	LEIGH	2006-02-15 04:34:33
104	PENELOPE	CRONYN	2006-02-15 04:34:33
105	SIDNEY	CROWE	2006-02-15 04:34:33
106	GROUCHO	DUNST	2006-02-15 04:34:33
107	GINA	DEGENERES	2006-02-15 04:34:33
108	WARREN	NOLTE	2006-02-15 04:34:33
109	SYLVESTER	DERN	2006-02-15 04:34:33
110	SUSAN	DAVIS	2006-02-15 04:34:33
111	CAMERON	ZELLWEGER	2006-02-15 04:34:33
112	RUSSELL	BACALL	2006-02-15 04:34:33
113	MORGAN	HOPKINS	2006-02-15 04:34:33
114	MORGAN	MCDORMAND	2006-02-15 04:34:33
115	HARRISON	BALE	2006-02-15 04:34:33
116	DAN	STREEP	2006-02-15 04:34:33
117	RENEE	TRACY	2006-02-15 04:34:33
118	CUBA	ALLEN	2006-02-15 04:34:33
119	WARREN	JACKMAN	2006-02-15 04:34:33
120	PENELOPE	MONROE	2006-02-15 04:34:33
121	LIZA	BERGMAN	2006-02-15 04:34:33
122	SALMA	NOLTE	2006-02-15 04:34:33
123	JULIANNE	DENCH	2006-02-15 04:34:33
124	SCARLETT	BENING	2006-02-15 04:34:33
125	ALBERT	NOLTE	2006-02-15 04:34:33
126	FRANCES	TOMEI	2006-02-15 04:34:33
127	KEVIN	GARLAND	2006-02-15 04:34:33
128	CATE	MCQUEEN	2006-02-15 04:34:33
129	DARYL	CRAWFORD	2006-02-15 04:34:33
130	GRETA	KEITEL	2006-02-15 04:34:33
131	JANE	JACKMAN	2006-02-15 04:34:33
132	ADAM	HOPPER	2006-02-15 04:34:33
133	RICHARD	PENN	2006-02-15 04:34:33
134	GENE	HOPKINS	2006-02-15 04:34:33
135	RITA	REYNOLDS	2006-02-15 04:34:33
136	ED	MANSFIELD	2006-02-15 04:34:33
137	MORGAN	WILLIAMS	2006-02-15 04:34:33
138	LUCILLE	DEE	2006-02-15 04:34:33
139	EWAN	GOODING	2006-02-15 04:34:33
140	WHOOPI	HURT	2006-02-15 04:34:33
141	CATE	HARRIS	2006-02-15 04:34:33
142	JADA	RYDER	2006-02-15 04:34:33
143	RIVER	DEAN	2006-02-15 04:34:33
144	ANGELA	WITHERSPOON	2006-02-15 04:34:33
145	KIM	ALLEN	2006-02-15 04:34:33
146	ALBERT	JOHANSSON	2006-02-15 04:34:33
147	FAY	WINSLET	2006-02-15 04:34:33
148	EMILY	DEE	2006-02-15 04:34:33
149	RUSSELL	TEMPLE	2006-02-15 04:34:33
150	JAYNE	NOLTE	2006-02-15 04:34:33
151	GEOFFREY	HESTON	2006-02-15 04:34:33
152	BEN	HARRIS	2006-02-15 04:34:33
153	MINNIE	KILMER	2006-02-15 04:34:33
154	MERYL	GIBSON	2006-02-15 04:34:33
155	IAN	TANDY	2006-02-15 04:34:33
156	FAY	WOOD	2006-02-15 04:34:33
157	GRETA	MALDEN	2006-02-15 04:34:33
158	VIVIEN	BASINGER	2006-02-15 04:34:33
159	LAURA	BRODY	2006-02-15 04:34:33
160	CHRIS	DEPP	2006-02-15 04:34:33
161	HARVEY	HOPE	2006-02-15 04:34:33
162	OPRAH	KILMER	2006-02-15 04:34:33
163	CHRISTOPHER	WEST	2006-02-15 04:34:33
164	HUMPHREY	WILLIS	2006-02-15 04:34:33
165	AL	GARLAND	2006-02-15 04:34:33
166	NICK	DEGENERES	2006-02-15 04:34:33
167	LAURENCE	BULLOCK	2006-02-15 04:34:33
168	WILL	WILSON	2006-02-15 04:34:33
169	KENNETH	HOFFMAN	2006-02-15 04:34:33
170	MENA	HOPPER	2006-02-15 04:34:33
171	OLYMPIA	PFEIFFER	2006-02-15 04:34:33
172	GROUCHO	WILLIAMS	2006-02-15 04:34:33
173	ALAN	DREYFUSS	2006-02-15 04:34:33
174	MICHAEL	BENING	2006-02-15 04:34:33
175	WILLIAM	HACKMAN	2006-02-15 04:34:33
176	JON	CHASE	2006-02-15 04:34:33
177	GENE	MCKELLEN	2006-02-15 04:34:33
178	LISA	MONROE	2006-02-15 04:34:33
179	ED	GUINESS	2006-02-15 04:34:33
180	JEFF	SILVERSTONE	2006-02-15 04:34:33
181	MATTHEW	CARREY	2006-02-15 04:34:33
182	DEBBIE	AKROYD	2006-02-15 04:34:33
183	RUSSELL	CLOSE	2006-02-15 04:34:33
184	HUMPHREY	GARLAND	2006-02-15 04:34:33
185	MICHAEL	BOLGER	2006-02-15 04:34:33
186	JULIA	ZELLWEGER	2006-02-15 04:34:33
187	RENEE	BALL	2006-02-15 04:34:33
188	ROCK	DUKAKIS	2006-02-15 04:34:33
189	CUBA	BIRCH	2006-02-15 04:34:33
190	AUDREY	BAILEY	2006-02-15 04:34:33
191	GREGORY	GOODING	2006-02-15 04:34:33
192	JOHN	SUVARI	2006-02-15 04:34:33
193	BURT	TEMPLE	2006-02-15 04:34:33
194	MERYL	ALLEN	2006-02-15 04:34:33
195	JAYNE	SILVERSTONE	2006-02-15 04:34:33
196	BELA	WALKEN	2006-02-15 04:34:33
197	REESE	WEST	2006-02-15 04:34:33
198	MARY	KEITEL	2006-02-15 04:34:33
199	JULIA	FAWCETT	2006-02-15 04:34:33
200	THORA	TEMPLE	2006-02-15 04:34:33
\.


--
-- Data for Name: address; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.address (address_id, address, address2, district, city_id, postal_code, phone, last_update) FROM stdin;
1	47 MySakila Drive	\N	 	300	\N	 	2006-02-15 04:45:30
2	28 MySQL Boulevard	\N	 	576	\N	 	2006-02-15 04:45:30
3	23 Workhaven Lane	\N	 	300	\N	 	2006-02-15 04:45:30
4	1411 Lillydale Drive	\N	 	576	\N	 	2006-02-15 04:45:30
5	1913 Hanoi Way	\N	 	463	35200	 	2006-02-15 04:45:30
6	1121 Loja Avenue	\N	 	449	17886	 	2006-02-15 04:45:30
7	692 Joliet Street	\N	 	38	83579	 	2006-02-15 04:45:30
8	1566 Inegl Manor	\N	 	349	53561	 	2006-02-15 04:45:30
9	53 Idfu Parkway	\N	 	361	42399	 	2006-02-15 04:45:30
10	1795 Santiago de Compostela Way	\N	 	295	18743	 	2006-02-15 04:45:30
11	900 Santiago de Compostela Parkway	\N	 	280	93896	 	2006-02-15 04:45:30
12	478 Joliet Way	\N	 	200	77948	 	2006-02-15 04:45:30
13	613 Korolev Drive	\N	 	329	45844	 	2006-02-15 04:45:30
14	1531 Sal Drive	\N	 	162	53628	 	2006-02-15 04:45:30
15	1542 Tarlac Parkway	\N	 	440	1027	 	2006-02-15 04:45:30
16	808 Bhopal Manor	\N	 	582	10672	 	2006-02-15 04:45:30
17	270 Amroha Parkway	\N	 	384	29610	 	2006-02-15 04:45:30
18	770 Bydgoszcz Avenue	\N	 	120	16266	 	2006-02-15 04:45:30
19	419 Iligan Lane	\N	 	76	72878	 	2006-02-15 04:45:30
20	360 Toulouse Parkway	\N	 	495	54308	 	2006-02-15 04:45:30
21	270 Toulon Boulevard	\N	 	156	81766	 	2006-02-15 04:45:30
22	320 Brest Avenue	\N	 	252	43331	 	2006-02-15 04:45:30
23	1417 Lancaster Avenue	\N	 	267	72192	 	2006-02-15 04:45:30
24	1688 Okara Way	\N	 	327	21954	 	2006-02-15 04:45:30
25	262 A Corua (La Corua) Parkway	\N	 	525	34418	 	2006-02-15 04:45:30
26	28 Charlotte Amalie Street	\N	 	443	37551	 	2006-02-15 04:45:30
27	1780 Hino Boulevard	\N	 	303	7716	 	2006-02-15 04:45:30
28	96 Tafuna Way	\N	 	128	99865	 	2006-02-15 04:45:30
29	934 San Felipe de Puerto Plata Street	\N	 	472	99780	 	2006-02-15 04:45:30
30	18 Duisburg Boulevard	\N	 	121	58327	 	2006-02-15 04:45:30
31	217 Botshabelo Place	\N	 	138	49521	 	2006-02-15 04:45:30
32	1425 Shikarpur Manor	\N	 	346	65599	 	2006-02-15 04:45:30
33	786 Aurora Avenue	\N	 	474	65750	 	2006-02-15 04:45:30
34	1668 Anpolis Street	\N	 	316	50199	 	2006-02-15 04:45:30
35	33 Gorontalo Way	\N	 	257	30348	 	2006-02-15 04:45:30
36	176 Mandaluyong Place	\N	 	239	65213	 	2006-02-15 04:45:30
37	127 Purnea (Purnia) Manor	\N	 	17	79388	 	2006-02-15 04:45:30
38	61 Tama Street	\N	 	284	94065	 	2006-02-15 04:45:30
39	391 Callao Drive	\N	 	544	34021	 	2006-02-15 04:45:30
40	334 Munger (Monghyr) Lane	\N	 	31	38145	 	2006-02-15 04:45:30
41	1440 Fukuyama Loop	\N	 	362	47929	 	2006-02-15 04:45:30
42	269 Cam Ranh Parkway	\N	 	115	34689	 	2006-02-15 04:45:30
43	306 Antofagasta Place	\N	 	569	3989	 	2006-02-15 04:45:30
44	671 Graz Street	\N	 	353	94399	 	2006-02-15 04:45:30
45	42 Brindisi Place	\N	 	586	16744	 	2006-02-15 04:45:30
46	1632 Bislig Avenue	\N	 	394	61117	 	2006-02-15 04:45:30
47	1447 Imus Way	\N	 	167	48942	 	2006-02-15 04:45:30
48	1998 Halifax Drive	\N	 	308	76022	 	2006-02-15 04:45:30
49	1718 Valencia Street	\N	 	27	37359	 	2006-02-15 04:45:30
50	46 Pjatigorsk Lane	\N	 	343	23616	 	2006-02-15 04:45:30
51	686 Garland Manor	\N	 	247	52535	 	2006-02-15 04:45:30
52	909 Garland Manor	\N	 	367	69367	 	2006-02-15 04:45:30
53	725 Isesaki Place	\N	 	237	74428	 	2006-02-15 04:45:30
54	115 Hidalgo Parkway	\N	 	379	80168	 	2006-02-15 04:45:30
55	1135 Izumisano Parkway	\N	 	171	48150	 	2006-02-15 04:45:30
56	939 Probolinggo Loop	\N	 	1	4166	 	2006-02-15 04:45:30
57	17 Kabul Boulevard	\N	 	355	38594	 	2006-02-15 04:45:30
58	1964 Allappuzha (Alleppey) Street	\N	 	227	48980	 	2006-02-15 04:45:30
59	1697 Kowloon and New Kowloon Loop	\N	 	49	57807	 	2006-02-15 04:45:30
60	1668 Saint Louis Place	\N	 	397	39072	 	2006-02-15 04:45:30
61	943 Tokat Street	\N	 	560	45428	 	2006-02-15 04:45:30
62	1114 Liepaja Street	\N	 	282	69226	 	2006-02-15 04:45:30
63	1213 Ranchi Parkway	\N	 	350	94352	 	2006-02-15 04:45:30
64	81 Hodeida Way	\N	 	231	55561	 	2006-02-15 04:45:30
65	915 Ponce Place	\N	 	56	83980	 	2006-02-15 04:45:30
66	1717 Guadalajara Lane	\N	 	441	85505	 	2006-02-15 04:45:30
67	1214 Hanoi Way	\N	 	306	67055	 	2006-02-15 04:45:30
68	1966 Amroha Avenue	\N	 	139	70385	 	2006-02-15 04:45:30
69	698 Otsu Street	\N	 	105	71110	 	2006-02-15 04:45:30
70	1150 Kimchon Manor	\N	 	321	96109	 	2006-02-15 04:45:30
71	1586 Guaruj Place	\N	 	579	5135	 	2006-02-15 04:45:30
72	57 Arlington Manor	\N	 	475	48960	 	2006-02-15 04:45:30
73	1031 Daugavpils Parkway	\N	 	63	59025	 	2006-02-15 04:45:30
74	1124 Buenaventura Drive	\N	 	13	6856	 	2006-02-15 04:45:30
75	492 Cam Ranh Street	\N	 	61	50805	 	2006-02-15 04:45:30
76	89 Allappuzha (Alleppey) Manor	\N	 	517	75444	 	2006-02-15 04:45:30
77	1947 Poos de Caldas Boulevard	\N	 	114	60951	 	2006-02-15 04:45:30
78	1206 Dos Quebradas Place	\N	 	431	20207	 	2006-02-15 04:45:30
79	1551 Rampur Lane	\N	 	108	72394	 	2006-02-15 04:45:30
80	602 Paarl Street	\N	 	402	98889	 	2006-02-15 04:45:30
81	1692 Ede Loop	\N	 	30	9223	 	2006-02-15 04:45:30
82	936 Salzburg Lane	\N	 	425	96709	 	2006-02-15 04:45:30
83	586 Tete Way	\N	 	256	1079	 	2006-02-15 04:45:30
84	1888 Kabul Drive	\N	 	217	20936	 	2006-02-15 04:45:30
85	320 Baiyin Parkway	\N	 	319	37307	 	2006-02-15 04:45:30
86	927 Baha Blanca Parkway	\N	 	479	9495	 	2006-02-15 04:45:30
87	929 Tallahassee Loop	\N	 	497	74671	 	2006-02-15 04:45:30
88	125 Citt del Vaticano Boulevard	\N	 	40	67912	 	2006-02-15 04:45:30
89	1557 Ktahya Boulevard	\N	 	88	88002	 	2006-02-15 04:45:30
90	870 Ashqelon Loop	\N	 	489	84931	 	2006-02-15 04:45:30
91	1740 Portoviejo Avenue	\N	 	480	29932	 	2006-02-15 04:45:30
92	1942 Ciparay Parkway	\N	 	113	82624	 	2006-02-15 04:45:30
93	1926 El Alto Avenue	\N	 	289	75543	 	2006-02-15 04:45:30
94	1952 Chatsworth Drive	\N	 	332	25958	 	2006-02-15 04:45:30
95	1370 Le Mans Avenue	\N	 	53	52163	 	2006-02-15 04:45:30
96	984 Effon-Alaiye Avenue	\N	 	183	17119	 	2006-02-15 04:45:30
97	832 Nakhon Sawan Manor	\N	 	592	49021	 	2006-02-15 04:45:30
98	152 Kitwe Parkway	\N	 	82	53182	 	2006-02-15 04:45:30
99	1697 Tanauan Lane	\N	 	399	22870	 	2006-02-15 04:45:30
100	1308 Arecibo Way	\N	 	41	30695	 	2006-02-15 04:45:30
101	1599 Plock Drive	\N	 	534	71986	 	2006-02-15 04:45:30
102	669 Firozabad Loop	\N	 	12	92265	 	2006-02-15 04:45:30
103	588 Vila Velha Manor	\N	 	268	51540	 	2006-02-15 04:45:30
104	1913 Kamakura Place	\N	 	238	97287	 	2006-02-15 04:45:30
105	733 Mandaluyong Place	\N	 	2	77459	 	2006-02-15 04:45:30
106	659 Vaduz Drive	\N	 	34	49708	 	2006-02-15 04:45:30
107	1177 Jelets Way	\N	 	220	3305	 	2006-02-15 04:45:30
108	1386 Yangor Avenue	\N	 	543	80720	 	2006-02-15 04:45:30
109	454 Nakhon Sawan Boulevard	\N	 	173	76383	 	2006-02-15 04:45:30
110	1867 San Juan Bautista Tuxtepec Avenue	\N	 	225	78311	 	2006-02-15 04:45:30
111	1532 Dzerzinsk Way	\N	 	334	9599	 	2006-02-15 04:45:30
112	1002 Ahmadnagar Manor	\N	 	213	93026	 	2006-02-15 04:45:30
113	682 Junan Way	\N	 	273	30418	 	2006-02-15 04:45:30
114	804 Elista Drive	\N	 	159	61069	 	2006-02-15 04:45:30
115	1378 Alvorada Avenue	\N	 	102	75834	 	2006-02-15 04:45:30
116	793 Cam Ranh Avenue	\N	 	292	87057	 	2006-02-15 04:45:30
117	1079 Tel Aviv-Jaffa Boulevard	\N	 	132	10885	 	2006-02-15 04:45:30
118	442 Rae Bareli Place	\N	 	148	24321	 	2006-02-15 04:45:30
119	1107 Nakhon Sawan Avenue	\N	 	365	75149	 	2006-02-15 04:45:30
120	544 Malm Parkway	\N	 	403	63502	 	2006-02-15 04:45:30
121	1967 Sincelejo Place	\N	 	176	73644	 	2006-02-15 04:45:30
122	333 Goinia Way	\N	 	185	78625	 	2006-02-15 04:45:30
123	1987 Coacalco de Berriozbal Loop	\N	 	476	96065	 	2006-02-15 04:45:30
124	241 Mosul Lane	\N	 	147	76157	 	2006-02-15 04:45:30
125	211 Chiayi Drive	\N	 	164	58186	 	2006-02-15 04:45:30
126	1175 Tanauan Way	\N	 	305	64615	 	2006-02-15 04:45:30
127	117 Boa Vista Way	\N	 	566	6804	 	2006-02-15 04:45:30
128	848 Tafuna Manor	\N	 	281	45142	 	2006-02-15 04:45:30
129	569 Baicheng Lane	\N	 	85	60304	 	2006-02-15 04:45:30
130	1666 Qomsheh Drive	\N	 	410	66255	 	2006-02-15 04:45:30
131	801 Hagonoy Drive	\N	 	484	8439	 	2006-02-15 04:45:30
132	1050 Garden Grove Avenue	\N	 	236	4999	 	2006-02-15 04:45:30
133	1854 Tieli Street	\N	 	302	15819	 	2006-02-15 04:45:30
134	758 Junan Lane	\N	 	190	82639	 	2006-02-15 04:45:30
135	1752 So Leopoldo Parkway	\N	 	345	14014	 	2006-02-15 04:45:30
136	898 Belm Manor	\N	 	87	49757	 	2006-02-15 04:45:30
137	261 Saint Louis Way	\N	 	541	83401	 	2006-02-15 04:45:30
138	765 Southampton Drive	\N	 	421	4285	 	2006-02-15 04:45:30
139	943 Johannesburg Avenue	\N	 	417	5892	 	2006-02-15 04:45:30
140	788 Atinsk Street	\N	 	211	81691	 	2006-02-15 04:45:30
141	1749 Daxian Place	\N	 	29	11044	 	2006-02-15 04:45:30
142	1587 Sullana Lane	\N	 	207	85769	 	2006-02-15 04:45:30
143	1029 Dzerzinsk Manor	\N	 	542	57519	 	2006-02-15 04:45:30
144	1666 Beni-Mellal Place	\N	 	123	13377	 	2006-02-15 04:45:30
145	928 Jaffna Loop	\N	 	172	93762	 	2006-02-15 04:45:30
146	483 Ljubertsy Parkway	\N	 	149	60562	 	2006-02-15 04:45:30
147	374 Bat Yam Boulevard	\N	 	266	97700	 	2006-02-15 04:45:30
148	1027 Songkhla Manor	\N	 	340	30861	 	2006-02-15 04:45:30
149	999 Sanaa Loop	\N	 	491	3439	 	2006-02-15 04:45:30
150	879 Newcastle Way	\N	 	499	90732	 	2006-02-15 04:45:30
151	1337 Lincoln Parkway	\N	 	555	99457	 	2006-02-15 04:45:30
152	1952 Pune Lane	\N	 	442	92150	 	2006-02-15 04:45:30
153	782 Mosul Street	\N	 	94	25545	 	2006-02-15 04:45:30
154	781 Shimonoseki Drive	\N	 	202	95444	 	2006-02-15 04:45:30
155	1560 Jelets Boulevard	\N	 	291	77777	 	2006-02-15 04:45:30
156	1963 Moscow Place	\N	 	354	64863	 	2006-02-15 04:45:30
157	456 Escobar Way	\N	 	232	36061	 	2006-02-15 04:45:30
158	798 Cianjur Avenue	\N	 	590	76990	 	2006-02-15 04:45:30
159	185 Novi Sad Place	\N	 	72	41778	 	2006-02-15 04:45:30
160	1367 Yantai Manor	\N	 	381	21294	 	2006-02-15 04:45:30
161	1386 Nakhon Sawan Boulevard	\N	 	420	53502	 	2006-02-15 04:45:30
162	369 Papeete Way	\N	 	187	66639	 	2006-02-15 04:45:30
163	1440 Compton Place	\N	 	307	81037	 	2006-02-15 04:45:30
164	1623 Baha Blanca Manor	\N	 	310	81511	 	2006-02-15 04:45:30
165	97 Shimoga Avenue	\N	 	533	44660	 	2006-02-15 04:45:30
166	1740 Le Mans Loop	\N	 	297	22853	 	2006-02-15 04:45:30
167	1287 Xiangfan Boulevard	\N	 	253	57844	 	2006-02-15 04:45:30
168	842 Salzburg Lane	\N	 	529	3313	 	2006-02-15 04:45:30
169	154 Tallahassee Loop	\N	 	199	62250	 	2006-02-15 04:45:30
170	710 San Felipe del Progreso Avenue	\N	 	304	76901	 	2006-02-15 04:45:30
171	1540 Wroclaw Drive	\N	 	107	62686	 	2006-02-15 04:45:30
172	475 Atinsk Way	\N	 	240	59571	 	2006-02-15 04:45:30
173	1294 Firozabad Drive	\N	 	407	70618	 	2006-02-15 04:45:30
174	1877 Ezhou Lane	\N	 	550	63337	 	2006-02-15 04:45:30
175	316 Uruapan Street	\N	 	223	58194	 	2006-02-15 04:45:30
176	29 Pyongyang Loop	\N	 	58	47753	 	2006-02-15 04:45:30
177	1010 Klerksdorp Way	\N	 	186	6802	 	2006-02-15 04:45:30
178	1848 Salala Boulevard	\N	 	373	25220	 	2006-02-15 04:45:30
179	431 Xiangtan Avenue	\N	 	18	4854	 	2006-02-15 04:45:30
180	757 Rustenburg Avenue	\N	 	483	89668	 	2006-02-15 04:45:30
181	146 Johannesburg Way	\N	 	330	54132	 	2006-02-15 04:45:30
182	1891 Rizhao Boulevard	\N	 	456	47288	 	2006-02-15 04:45:30
183	1089 Iwatsuki Avenue	\N	 	270	35109	 	2006-02-15 04:45:30
184	1410 Benin City Parkway	\N	 	405	29747	 	2006-02-15 04:45:30
185	682 Garden Grove Place	\N	 	333	67497	 	2006-02-15 04:45:30
186	533 al-Ayn Boulevard	\N	 	126	8862	 	2006-02-15 04:45:30
187	1839 Szkesfehrvr Parkway	\N	 	317	55709	 	2006-02-15 04:45:30
188	741 Ambattur Manor	\N	 	438	43310	 	2006-02-15 04:45:30
189	927 Barcelona Street	\N	 	467	65121	 	2006-02-15 04:45:30
190	435 0 Way	\N	 	195	74750	 	2006-02-15 04:45:30
191	140 Chiayi Parkway	\N	 	506	38982	 	2006-02-15 04:45:30
192	1166 Changhwa Street	\N	 	62	58852	 	2006-02-15 04:45:30
193	891 Novi Sad Manor	\N	 	383	5379	 	2006-02-15 04:45:30
194	605 Rio Claro Parkway	\N	 	513	49348	 	2006-02-15 04:45:30
195	1077 San Felipe de Puerto Plata Place	\N	 	369	65387	 	2006-02-15 04:45:30
196	9 San Miguel de Tucumn Manor	\N	 	169	90845	 	2006-02-15 04:45:30
197	447 Surakarta Loop	\N	 	271	10428	 	2006-02-15 04:45:30
198	345 Oshawa Boulevard	\N	 	204	32114	 	2006-02-15 04:45:30
199	1792 Valle de la Pascua Place	\N	 	477	15540	 	2006-02-15 04:45:30
200	1074 Binzhou Manor	\N	 	325	36490	 	2006-02-15 04:45:30
201	817 Bradford Loop	\N	 	109	89459	 	2006-02-15 04:45:30
202	955 Bamenda Way	\N	 	218	1545	 	2006-02-15 04:45:30
203	1149 A Corua (La Corua) Boulevard	\N	 	194	95824	 	2006-02-15 04:45:30
204	387 Mwene-Ditu Drive	\N	 	35	8073	 	2006-02-15 04:45:30
205	68 Molodetno Manor	\N	 	575	4662	 	2006-02-15 04:45:30
206	642 Nador Drive	\N	 	77	3924	 	2006-02-15 04:45:30
207	1688 Nador Lane	\N	 	184	61613	 	2006-02-15 04:45:30
208	1215 Pyongyang Parkway	\N	 	557	25238	 	2006-02-15 04:45:30
209	1679 Antofagasta Street	\N	 	122	86599	 	2006-02-15 04:45:30
210	1304 s-Hertogenbosch Way	\N	 	83	10925	 	2006-02-15 04:45:30
211	850 Salala Loop	\N	 	371	10800	 	2006-02-15 04:45:30
212	624 Oshawa Boulevard	\N	 	51	89959	 	2006-02-15 04:45:30
213	43 Dadu Avenue	\N	 	74	4855	 	2006-02-15 04:45:30
214	751 Lima Loop	\N	 	7	99405	 	2006-02-15 04:45:30
215	1333 Haldia Street	\N	 	174	82161	 	2006-02-15 04:45:30
216	660 Jedda Boulevard	\N	 	65	25053	 	2006-02-15 04:45:30
217	1001 Miyakonojo Lane	\N	 	518	67924	 	2006-02-15 04:45:30
218	226 Brest Manor	\N	 	508	2299	 	2006-02-15 04:45:30
219	1229 Valencia Parkway	\N	 	498	99124	 	2006-02-15 04:45:30
220	1201 Qomsheh Manor	\N	 	28	21464	 	2006-02-15 04:45:30
221	866 Shivapuri Manor	\N	 	448	22474	 	2006-02-15 04:45:30
222	1168 Najafabad Parkway	\N	 	251	40301	 	2006-02-15 04:45:30
223	1244 Allappuzha (Alleppey) Place	\N	 	567	20657	 	2006-02-15 04:45:30
224	1842 Luzinia Boulevard	\N	 	593	94420	 	2006-02-15 04:45:30
225	1926 Gingoog Street	\N	 	511	22824	 	2006-02-15 04:45:30
226	810 Palghat (Palakkad) Boulevard	\N	 	235	73431	 	2006-02-15 04:45:30
227	1820 Maring Parkway	\N	 	324	88307	 	2006-02-15 04:45:30
228	60 Poos de Caldas Street	\N	 	243	82338	 	2006-02-15 04:45:30
229	1014 Loja Manor	\N	 	22	66851	 	2006-02-15 04:45:30
230	201 Effon-Alaiye Way	\N	 	37	64344	 	2006-02-15 04:45:30
231	430 Alessandria Loop	\N	 	439	47446	 	2006-02-15 04:45:30
232	754 Valencia Place	\N	 	406	87911	 	2006-02-15 04:45:30
233	356 Olomouc Manor	\N	 	26	93323	 	2006-02-15 04:45:30
234	1256 Bislig Boulevard	\N	 	86	50598	 	2006-02-15 04:45:30
235	954 Kimchon Place	\N	 	559	42420	 	2006-02-15 04:45:30
236	885 Yingkou Manor	\N	 	596	31390	 	2006-02-15 04:45:30
237	1736 Cavite Place	\N	 	216	98775	 	2006-02-15 04:45:30
238	346 Skikda Parkway	\N	 	233	90628	 	2006-02-15 04:45:30
239	98 Stara Zagora Boulevard	\N	 	96	76448	 	2006-02-15 04:45:30
240	1479 Rustenburg Boulevard	\N	 	527	18727	 	2006-02-15 04:45:30
241	647 A Corua (La Corua) Street	\N	 	357	36971	 	2006-02-15 04:45:30
242	1964 Gijn Manor	\N	 	473	14408	 	2006-02-15 04:45:30
243	47 Syktyvkar Lane	\N	 	118	22236	 	2006-02-15 04:45:30
244	1148 Saarbrcken Parkway	\N	 	226	1921	 	2006-02-15 04:45:30
245	1103 Bilbays Parkway	\N	 	578	87660	 	2006-02-15 04:45:30
246	1246 Boksburg Parkway	\N	 	422	28349	 	2006-02-15 04:45:30
247	1483 Pathankot Street	\N	 	454	37288	 	2006-02-15 04:45:30
248	582 Papeete Loop	\N	 	294	27722	 	2006-02-15 04:45:30
249	300 Junan Street	\N	 	553	81314	 	2006-02-15 04:45:30
250	829 Grand Prairie Way	\N	 	328	6461	 	2006-02-15 04:45:30
251	1473 Changhwa Parkway	\N	 	124	75933	 	2006-02-15 04:45:30
252	1309 Weifang Street	\N	 	520	57338	 	2006-02-15 04:45:30
253	1760 Oshawa Manor	\N	 	535	38140	 	2006-02-15 04:45:30
254	786 Stara Zagora Way	\N	 	390	98332	 	2006-02-15 04:45:30
255	1966 Tonghae Street	\N	 	198	36481	 	2006-02-15 04:45:30
256	1497 Yuzhou Drive	\N	 	312	3433	 	2006-02-15 04:45:30
258	752 Ondo Loop	\N	 	338	32474	 	2006-02-15 04:45:30
259	1338 Zalantun Lane	\N	 	413	45403	 	2006-02-15 04:45:30
260	127 Iwakuni Boulevard	\N	 	192	20777	 	2006-02-15 04:45:30
261	51 Laredo Avenue	\N	 	342	68146	 	2006-02-15 04:45:30
262	771 Yaound Manor	\N	 	64	86768	 	2006-02-15 04:45:30
263	532 Toulon Street	\N	 	460	69517	 	2006-02-15 04:45:30
264	1027 Banjul Place	\N	 	197	50390	 	2006-02-15 04:45:30
265	1158 Mandi Bahauddin Parkway	\N	 	136	98484	 	2006-02-15 04:45:30
266	862 Xintai Lane	\N	 	548	30065	 	2006-02-15 04:45:30
267	816 Cayenne Parkway	\N	 	414	93629	 	2006-02-15 04:45:30
268	1831 Nam Dinh Loop	\N	 	323	51990	 	2006-02-15 04:45:30
269	446 Kirovo-Tepetsk Lane	\N	 	203	19428	 	2006-02-15 04:45:30
270	682 Halisahar Place	\N	 	378	20536	 	2006-02-15 04:45:30
271	1587 Loja Manor	\N	 	447	5410	 	2006-02-15 04:45:30
272	1762 Paarl Parkway	\N	 	298	53928	 	2006-02-15 04:45:30
273	1519 Ilorin Place	\N	 	395	49298	 	2006-02-15 04:45:30
274	920 Kumbakonam Loop	\N	 	446	75090	 	2006-02-15 04:45:30
275	906 Goinia Way	\N	 	255	83565	 	2006-02-15 04:45:30
276	1675 Xiangfan Manor	\N	 	283	11763	 	2006-02-15 04:45:30
277	85 San Felipe de Puerto Plata Drive	\N	 	584	46063	 	2006-02-15 04:45:30
278	144 South Hill Loop	\N	 	445	2012	 	2006-02-15 04:45:30
279	1884 Shikarpur Avenue	\N	 	263	85548	 	2006-02-15 04:45:30
280	1980 Kamjanets-Podilskyi Street	\N	 	404	89502	 	2006-02-15 04:45:30
281	1944 Bamenda Way	\N	 	573	24645	 	2006-02-15 04:45:30
282	556 Baybay Manor	\N	 	374	55802	 	2006-02-15 04:45:30
283	457 Tongliao Loop	\N	 	222	56254	 	2006-02-15 04:45:30
284	600 Bradford Street	\N	 	514	96204	 	2006-02-15 04:45:30
285	1006 Santa Brbara dOeste Manor	\N	 	389	36229	 	2006-02-15 04:45:30
286	1308 Sumy Loop	\N	 	175	30657	 	2006-02-15 04:45:30
287	1405 Chisinau Place	\N	 	411	8160	 	2006-02-15 04:45:30
288	226 Halifax Street	\N	 	277	58492	 	2006-02-15 04:45:30
289	1279 Udine Parkway	\N	 	69	75860	 	2006-02-15 04:45:30
290	1336 Benin City Drive	\N	 	386	46044	 	2006-02-15 04:45:30
291	1155 Liaocheng Place	\N	 	152	22650	 	2006-02-15 04:45:30
292	1993 Tabuk Lane	\N	 	522	64221	 	2006-02-15 04:45:30
293	86 Higashiosaka Lane	\N	 	563	33768	 	2006-02-15 04:45:30
294	1912 Allende Manor	\N	 	279	58124	 	2006-02-15 04:45:30
295	544 Tarsus Boulevard	\N	 	562	53145	 	2006-02-15 04:45:30
296	1936 Cuman Avenue	\N	 	433	61195	 	2006-02-15 04:45:30
297	1192 Tongliao Street	\N	 	470	19065	 	2006-02-15 04:45:30
298	44 Najafabad Way	\N	 	146	61391	 	2006-02-15 04:45:30
299	32 Pudukkottai Lane	\N	 	140	38834	 	2006-02-15 04:45:30
300	661 Chisinau Lane	\N	 	274	8856	 	2006-02-15 04:45:30
301	951 Stara Zagora Manor	\N	 	400	98573	 	2006-02-15 04:45:30
302	922 Vila Velha Loop	\N	 	9	4085	 	2006-02-15 04:45:30
303	898 Jining Lane	\N	 	387	40070	 	2006-02-15 04:45:30
304	1635 Kuwana Boulevard	\N	 	205	52137	 	2006-02-15 04:45:30
305	41 El Alto Parkway	\N	 	398	56883	 	2006-02-15 04:45:30
306	1883 Maikop Lane	\N	 	254	68469	 	2006-02-15 04:45:30
307	1908 Gaziantep Place	\N	 	536	58979	 	2006-02-15 04:45:30
308	687 Alessandria Parkway	\N	 	455	57587	 	2006-02-15 04:45:30
309	827 Yuncheng Drive	\N	 	99	79047	 	2006-02-15 04:45:30
310	913 Coacalco de Berriozbal Loop	\N	 	33	42141	 	2006-02-15 04:45:30
311	715 So Bernardo do Campo Lane	\N	 	507	84804	 	2006-02-15 04:45:30
312	1354 Siegen Street	\N	 	25	80184	 	2006-02-15 04:45:30
313	1191 Sungai Petani Boulevard	\N	 	262	9668	 	2006-02-15 04:45:30
314	1224 Huejutla de Reyes Boulevard	\N	 	91	70923	 	2006-02-15 04:45:30
315	543 Bergamo Avenue	\N	 	215	59686	 	2006-02-15 04:45:30
316	746 Joliet Lane	\N	 	286	94878	 	2006-02-15 04:45:30
317	780 Kimberley Way	\N	 	515	17032	 	2006-02-15 04:45:30
318	1774 Yaound Place	\N	 	166	91400	 	2006-02-15 04:45:30
319	1957 Yantai Lane	\N	 	490	59255	 	2006-02-15 04:45:30
320	1542 Lubumbashi Boulevard	\N	 	57	62472	 	2006-02-15 04:45:30
321	651 Pathankot Loop	\N	 	336	59811	 	2006-02-15 04:45:30
322	1359 Zhoushan Parkway	\N	 	545	29763	 	2006-02-15 04:45:30
323	1769 Iwaki Lane	\N	 	97	25787	 	2006-02-15 04:45:30
324	1145 Vilnius Manor	\N	 	451	73170	 	2006-02-15 04:45:30
325	1892 Nabereznyje Telny Lane	\N	 	516	28396	 	2006-02-15 04:45:30
326	470 Boksburg Street	\N	 	81	97960	 	2006-02-15 04:45:30
327	1427 A Corua (La Corua) Place	\N	 	45	85799	 	2006-02-15 04:45:30
328	479 San Felipe del Progreso Avenue	\N	 	130	54949	 	2006-02-15 04:45:30
329	867 Benin City Avenue	\N	 	591	78543	 	2006-02-15 04:45:30
330	981 Kumbakonam Place	\N	 	89	87611	 	2006-02-15 04:45:30
331	1016 Iwakuni Street	\N	 	269	49833	 	2006-02-15 04:45:30
332	663 Baha Blanca Parkway	\N	 	5	33463	 	2006-02-15 04:45:30
333	1860 Taguig Loop	\N	 	119	59550	 	2006-02-15 04:45:30
334	1816 Bydgoszcz Loop	\N	 	234	64308	 	2006-02-15 04:45:30
335	587 Benguela Manor	\N	 	42	91590	 	2006-02-15 04:45:30
336	430 Kumbakonam Drive	\N	 	457	28814	 	2006-02-15 04:45:30
337	1838 Tabriz Lane	\N	 	143	1195	 	2006-02-15 04:45:30
338	431 Szkesfehrvr Avenue	\N	 	48	57828	 	2006-02-15 04:45:30
339	503 Sogamoso Loop	\N	 	505	49812	 	2006-02-15 04:45:30
340	507 Smolensk Loop	\N	 	492	22971	 	2006-02-15 04:45:30
341	1920 Weifang Avenue	\N	 	427	15643	 	2006-02-15 04:45:30
342	124 al-Manama Way	\N	 	382	52368	 	2006-02-15 04:45:30
343	1443 Mardan Street	\N	 	392	31483	 	2006-02-15 04:45:30
344	1909 Benguela Lane	\N	 	581	19913	 	2006-02-15 04:45:30
345	68 Ponce Parkway	\N	 	201	85926	 	2006-02-15 04:45:30
346	1217 Konotop Avenue	\N	 	151	504	 	2006-02-15 04:45:30
347	1293 Nam Dinh Way	\N	 	84	71583	 	2006-02-15 04:45:30
348	785 Vaduz Street	\N	 	335	36170	 	2006-02-15 04:45:30
349	1516 Escobar Drive	\N	 	370	46069	 	2006-02-15 04:45:30
350	1628 Nagareyama Lane	\N	 	453	60079	 	2006-02-15 04:45:30
351	1157 Nyeri Loop	\N	 	320	56380	 	2006-02-15 04:45:30
352	1673 Tangail Drive	\N	 	137	26857	 	2006-02-15 04:45:30
353	381 Kabul Way	\N	 	209	87272	 	2006-02-15 04:45:30
354	953 Hodeida Street	\N	 	221	18841	 	2006-02-15 04:45:30
355	469 Nakhon Sawan Street	\N	 	531	58866	 	2006-02-15 04:45:30
356	1378 Beira Loop	\N	 	597	40792	 	2006-02-15 04:45:30
357	1641 Changhwa Place	\N	 	52	37636	 	2006-02-15 04:45:30
358	1698 Southport Loop	\N	 	393	49009	 	2006-02-15 04:45:30
359	519 Nyeri Manor	\N	 	461	37650	 	2006-02-15 04:45:30
360	619 Hunuco Avenue	\N	 	331	81508	 	2006-02-15 04:45:30
361	45 Aparecida de Goinia Place	\N	 	464	7431	 	2006-02-15 04:45:30
362	482 Kowloon and New Kowloon Manor	\N	 	90	97056	 	2006-02-15 04:45:30
363	604 Bern Place	\N	 	429	5373	 	2006-02-15 04:45:30
364	1623 Kingstown Drive	\N	 	20	91299	 	2006-02-15 04:45:30
365	1009 Zanzibar Lane	\N	 	32	64875	 	2006-02-15 04:45:30
366	114 Jalib al-Shuyukh Manor	\N	 	585	60440	 	2006-02-15 04:45:30
367	1163 London Parkway	\N	 	66	6066	 	2006-02-15 04:45:30
368	1658 Jastrzebie-Zdrj Loop	\N	 	372	96584	 	2006-02-15 04:45:30
369	817 Laredo Avenue	\N	 	188	77449	 	2006-02-15 04:45:30
370	1565 Tangail Manor	\N	 	377	45750	 	2006-02-15 04:45:30
371	1912 Emeishan Drive	\N	 	50	33050	 	2006-02-15 04:45:30
372	230 Urawa Drive	\N	 	8	2738	 	2006-02-15 04:45:30
373	1922 Miraj Way	\N	 	356	13203	 	2006-02-15 04:45:30
374	433 Florencia Street	\N	 	250	91330	 	2006-02-15 04:45:30
375	1049 Matamoros Parkway	\N	 	191	69640	 	2006-02-15 04:45:30
376	1061 Ede Avenue	\N	 	98	57810	 	2006-02-15 04:45:30
377	154 Oshawa Manor	\N	 	415	72771	 	2006-02-15 04:45:30
378	1191 Tandil Drive	\N	 	523	6362	 	2006-02-15 04:45:30
379	1133 Rizhao Avenue	\N	 	572	2800	 	2006-02-15 04:45:30
380	1519 Santiago de los Caballeros Loop	\N	 	348	22025	 	2006-02-15 04:45:30
381	1618 Olomouc Manor	\N	 	285	26385	 	2006-02-15 04:45:30
382	220 Hidalgo Drive	\N	 	265	45298	 	2006-02-15 04:45:30
383	686 Donostia-San Sebastin Lane	\N	 	471	97390	 	2006-02-15 04:45:30
384	97 Mogiljov Lane	\N	 	73	89294	 	2006-02-15 04:45:30
385	1642 Charlotte Amalie Drive	\N	 	549	75442	 	2006-02-15 04:45:30
386	1368 Maracabo Boulevard	\N	 	493	32716	 	2006-02-15 04:45:30
387	401 Sucre Boulevard	\N	 	322	25007	 	2006-02-15 04:45:30
388	368 Hunuco Boulevard	\N	 	360	17165	 	2006-02-15 04:45:30
389	500 Lincoln Parkway	\N	 	210	95509	 	2006-02-15 04:45:30
390	102 Chapra Drive	\N	 	521	14073	 	2006-02-15 04:45:30
391	1793 Meixian Place	\N	 	258	33535	 	2006-02-15 04:45:30
392	514 Ife Way	\N	 	315	69973	 	2006-02-15 04:45:30
393	717 Changzhou Lane	\N	 	104	21615	 	2006-02-15 04:45:30
394	753 Ilorin Avenue	\N	 	157	3656	 	2006-02-15 04:45:30
395	1337 Mit Ghamr Avenue	\N	 	358	29810	 	2006-02-15 04:45:30
396	767 Pyongyang Drive	\N	 	229	83536	 	2006-02-15 04:45:30
397	614 Pak Kret Street	\N	 	6	27796	 	2006-02-15 04:45:30
398	954 Lapu-Lapu Way	\N	 	278	8816	 	2006-02-15 04:45:30
399	331 Bydgoszcz Parkway	\N	 	181	966	 	2006-02-15 04:45:30
400	1152 Citrus Heights Manor	\N	 	15	5239	 	2006-02-15 04:45:30
401	168 Cianjur Manor	\N	 	228	73824	 	2006-02-15 04:45:30
402	616 Hagonoy Avenue	\N	 	39	46043	 	2006-02-15 04:45:30
403	1190 0 Place	\N	 	44	10417	 	2006-02-15 04:45:30
404	734 Bchar Place	\N	 	375	30586	 	2006-02-15 04:45:30
405	530 Lausanne Lane	\N	 	135	11067	 	2006-02-15 04:45:30
406	454 Patiala Lane	\N	 	276	13496	 	2006-02-15 04:45:30
407	1346 Mysore Drive	\N	 	92	61507	 	2006-02-15 04:45:30
408	990 Etawah Loop	\N	 	564	79940	 	2006-02-15 04:45:30
409	1266 Laredo Parkway	\N	 	380	7664	 	2006-02-15 04:45:30
410	88 Nagaon Manor	\N	 	524	86868	 	2006-02-15 04:45:30
411	264 Bhimavaram Manor	\N	 	111	54749	 	2006-02-15 04:45:30
412	1639 Saarbrcken Drive	\N	 	437	9827	 	2006-02-15 04:45:30
413	692 Amroha Drive	\N	 	230	35575	 	2006-02-15 04:45:30
414	1936 Lapu-Lapu Parkway	\N	 	141	7122	 	2006-02-15 04:45:30
415	432 Garden Grove Street	\N	 	430	65630	 	2006-02-15 04:45:30
416	1445 Carmen Parkway	\N	 	117	70809	 	2006-02-15 04:45:30
417	791 Salinas Street	\N	 	208	40509	 	2006-02-15 04:45:30
418	126 Acua Parkway	\N	 	71	58888	 	2006-02-15 04:45:30
419	397 Sunnyvale Avenue	\N	 	19	55566	 	2006-02-15 04:45:30
420	992 Klerksdorp Loop	\N	 	23	33711	 	2006-02-15 04:45:30
421	966 Arecibo Loop	\N	 	134	94018	 	2006-02-15 04:45:30
422	289 Santo Andr Manor	\N	 	16	72410	 	2006-02-15 04:45:30
423	437 Chungho Drive	\N	 	450	59489	 	2006-02-15 04:45:30
424	1948 Bayugan Parkway	\N	 	264	60622	 	2006-02-15 04:45:30
425	1866 al-Qatif Avenue	\N	 	155	89420	 	2006-02-15 04:45:30
426	1661 Abha Drive	\N	 	416	14400	 	2006-02-15 04:45:30
427	1557 Cape Coral Parkway	\N	 	293	46875	 	2006-02-15 04:45:30
428	1727 Matamoros Place	\N	 	465	78813	 	2006-02-15 04:45:30
429	1269 Botosani Manor	\N	 	468	47394	 	2006-02-15 04:45:30
430	355 Vitria de Santo Anto Way	\N	 	452	81758	 	2006-02-15 04:45:30
431	1596 Acua Parkway	\N	 	418	70425	 	2006-02-15 04:45:30
432	259 Ipoh Drive	\N	 	189	64964	 	2006-02-15 04:45:30
433	1823 Hoshiarpur Lane	\N	 	510	33191	 	2006-02-15 04:45:30
434	1404 Taguig Drive	\N	 	547	87212	 	2006-02-15 04:45:30
435	740 Udaipur Lane	\N	 	150	33505	 	2006-02-15 04:45:30
436	287 Cuautla Boulevard	\N	 	501	72736	 	2006-02-15 04:45:30
437	1766 Almirante Brown Street	\N	 	364	63104	 	2006-02-15 04:45:30
438	596 Huixquilucan Place	\N	 	351	65892	 	2006-02-15 04:45:30
439	1351 Aparecida de Goinia Parkway	\N	 	391	41775	 	2006-02-15 04:45:30
440	722 Bradford Lane	\N	 	249	90920	 	2006-02-15 04:45:30
441	983 Santa F Way	\N	 	565	47472	 	2006-02-15 04:45:30
442	1245 Ibirit Way	\N	 	290	40926	 	2006-02-15 04:45:30
443	1836 Korla Parkway	\N	 	272	55405	 	2006-02-15 04:45:30
444	231 Kaliningrad Place	\N	 	70	57833	 	2006-02-15 04:45:30
445	495 Bhimavaram Lane	\N	 	144	3	 	2006-02-15 04:45:30
446	1924 Shimonoseki Drive	\N	 	59	52625	 	2006-02-15 04:45:30
447	105 Dzerzinsk Manor	\N	 	540	48570	 	2006-02-15 04:45:30
448	614 Denizli Parkway	\N	 	486	29444	 	2006-02-15 04:45:30
449	1289 Belm Boulevard	\N	 	530	88306	 	2006-02-15 04:45:30
450	203 Tambaram Street	\N	 	161	73942	 	2006-02-15 04:45:30
451	1704 Tambaram Manor	\N	 	554	2834	 	2006-02-15 04:45:30
452	207 Cuernavaca Loop	\N	 	352	52671	 	2006-02-15 04:45:30
453	319 Springs Loop	\N	 	160	99552	 	2006-02-15 04:45:30
454	956 Nam Dinh Manor	\N	 	481	21872	 	2006-02-15 04:45:30
455	1947 Paarl Way	\N	 	509	23636	 	2006-02-15 04:45:30
456	814 Simferopol Loop	\N	 	154	48745	 	2006-02-15 04:45:30
457	535 Ahmadnagar Manor	\N	 	3	41136	 	2006-02-15 04:45:30
458	138 Caracas Boulevard	\N	 	326	16790	 	2006-02-15 04:45:30
459	251 Florencia Drive	\N	 	556	16119	 	2006-02-15 04:45:30
460	659 Gatineau Boulevard	\N	 	153	28587	 	2006-02-15 04:45:30
461	1889 Valparai Way	\N	 	600	75559	 	2006-02-15 04:45:30
462	1485 Bratislava Place	\N	 	435	83183	 	2006-02-15 04:45:30
463	935 Aden Boulevard	\N	 	532	64709	 	2006-02-15 04:45:30
464	76 Kermanshah Manor	\N	 	423	23343	 	2006-02-15 04:45:30
465	734 Tanshui Avenue	\N	 	170	70664	 	2006-02-15 04:45:30
466	118 Jaffna Loop	\N	 	182	10447	 	2006-02-15 04:45:30
467	1621 Tongliao Avenue	\N	 	558	22173	 	2006-02-15 04:45:30
468	1844 Usak Avenue	\N	 	196	84461	 	2006-02-15 04:45:30
469	1872 Toulon Loop	\N	 	428	7939	 	2006-02-15 04:45:30
470	1088 Ibirit Place	\N	 	595	88502	 	2006-02-15 04:45:30
471	1322 Mosul Parkway	\N	 	145	95400	 	2006-02-15 04:45:30
472	1447 Chatsworth Place	\N	 	129	41545	 	2006-02-15 04:45:30
473	1257 Guadalajara Street	\N	 	78	33599	 	2006-02-15 04:45:30
474	1469 Plock Lane	\N	 	388	95835	 	2006-02-15 04:45:30
475	434 Ourense (Orense) Manor	\N	 	206	14122	 	2006-02-15 04:45:30
476	270 Tambaram Parkway	\N	 	244	9668	 	2006-02-15 04:45:30
477	1786 Salinas Place	\N	 	359	66546	 	2006-02-15 04:45:30
478	1078 Stara Zagora Drive	\N	 	301	69221	 	2006-02-15 04:45:30
479	1854 Okara Boulevard	\N	 	158	42123	 	2006-02-15 04:45:30
480	421 Yaound Street	\N	 	385	11363	 	2006-02-15 04:45:30
481	1153 Allende Way	\N	 	179	20336	 	2006-02-15 04:45:30
482	808 Naala-Porto Parkway	\N	 	500	41060	 	2006-02-15 04:45:30
483	632 Usolje-Sibirskoje Parkway	\N	 	36	73085	 	2006-02-15 04:45:30
484	98 Pyongyang Boulevard	\N	 	11	88749	 	2006-02-15 04:45:30
485	984 Novoterkassk Loop	\N	 	180	28165	 	2006-02-15 04:45:30
486	64 Korla Street	\N	 	347	25145	 	2006-02-15 04:45:30
487	1785 So Bernardo do Campo Street	\N	 	125	71182	 	2006-02-15 04:45:30
488	698 Jelets Boulevard	\N	 	142	2596	 	2006-02-15 04:45:30
489	1297 Alvorada Parkway	\N	 	587	11839	 	2006-02-15 04:45:30
490	1909 Dayton Avenue	\N	 	469	88513	 	2006-02-15 04:45:30
491	1789 Saint-Denis Parkway	\N	 	4	8268	 	2006-02-15 04:45:30
492	185 Mannheim Lane	\N	 	408	23661	 	2006-02-15 04:45:30
493	184 Mandaluyong Street	\N	 	288	94239	 	2006-02-15 04:45:30
494	591 Sungai Petani Drive	\N	 	376	46400	 	2006-02-15 04:45:30
495	656 Matamoros Drive	\N	 	487	19489	 	2006-02-15 04:45:30
496	775 ostka Drive	\N	 	337	22358	 	2006-02-15 04:45:30
497	1013 Tabuk Boulevard	\N	 	261	96203	 	2006-02-15 04:45:30
498	319 Plock Parkway	\N	 	504	26101	 	2006-02-15 04:45:30
499	1954 Kowloon and New Kowloon Way	\N	 	434	63667	 	2006-02-15 04:45:30
500	362 Rajkot Lane	\N	 	47	98030	 	2006-02-15 04:45:30
501	1060 Tandil Lane	\N	 	432	72349	 	2006-02-15 04:45:30
502	1515 Korla Way	\N	 	589	57197	 	2006-02-15 04:45:30
503	1416 San Juan Bautista Tuxtepec Avenue	\N	 	444	50592	 	2006-02-15 04:45:30
504	1 Valle de Santiago Avenue	\N	 	93	86208	 	2006-02-15 04:45:30
505	519 Brescia Parkway	\N	 	318	69504	 	2006-02-15 04:45:30
506	414 Mandaluyong Street	\N	 	314	16370	 	2006-02-15 04:45:30
507	1197 Sokoto Boulevard	\N	 	478	87687	 	2006-02-15 04:45:30
508	496 Celaya Drive	\N	 	552	90797	 	2006-02-15 04:45:30
509	786 Matsue Way	\N	 	245	37469	 	2006-02-15 04:45:30
510	48 Maracabo Place	\N	 	519	1570	 	2006-02-15 04:45:30
511	1152 al-Qatif Lane	\N	 	412	44816	 	2006-02-15 04:45:30
512	1269 Ipoh Avenue	\N	 	163	54674	 	2006-02-15 04:45:30
513	758 Korolev Parkway	\N	 	568	75474	 	2006-02-15 04:45:30
514	1747 Rustenburg Place	\N	 	110	51369	 	2006-02-15 04:45:30
515	886 Tonghae Place	\N	 	259	19450	 	2006-02-15 04:45:30
516	1574 Goinia Boulevard	\N	 	502	39529	 	2006-02-15 04:45:30
517	548 Uruapan Street	\N	 	312	35653	 	2006-02-15 04:45:30
519	962 Tama Loop	\N	 	583	65952	 	2006-02-15 04:45:30
520	1778 Gijn Manor	\N	 	594	35156	 	2006-02-15 04:45:30
521	568 Dhule (Dhulia) Loop	\N	 	127	92568	 	2006-02-15 04:45:30
522	1768 Udine Loop	\N	 	60	32347	 	2006-02-15 04:45:30
523	608 Birgunj Parkway	\N	 	116	400	 	2006-02-15 04:45:30
524	680 A Corua (La Corua) Manor	\N	 	482	49806	 	2006-02-15 04:45:30
525	1949 Sanya Street	\N	 	224	61244	 	2006-02-15 04:45:30
526	617 Klerksdorp Place	\N	 	366	94707	 	2006-02-15 04:45:30
527	1993 0 Loop	\N	 	588	41214	 	2006-02-15 04:45:30
528	1176 Southend-on-Sea Manor	\N	 	458	81651	 	2006-02-15 04:45:30
529	600 Purnea (Purnia) Avenue	\N	 	571	18043	 	2006-02-15 04:45:30
530	1003 Qinhuangdao Street	\N	 	419	25972	 	2006-02-15 04:45:30
531	1986 Sivas Place	\N	 	551	95775	 	2006-02-15 04:45:30
532	1427 Tabuk Place	\N	 	101	31342	 	2006-02-15 04:45:30
533	556 Asuncin Way	\N	 	339	35364	 	2006-02-15 04:45:30
534	486 Ondo Parkway	\N	 	67	35202	 	2006-02-15 04:45:30
535	635 Brest Manor	\N	 	75	40899	 	2006-02-15 04:45:30
536	166 Jinchang Street	\N	 	165	86760	 	2006-02-15 04:45:30
537	958 Sagamihara Lane	\N	 	287	88408	 	2006-02-15 04:45:30
538	1817 Livorno Way	\N	 	100	79401	 	2006-02-15 04:45:30
539	1332 Gaziantep Lane	\N	 	80	22813	 	2006-02-15 04:45:30
540	949 Allende Lane	\N	 	24	67521	 	2006-02-15 04:45:30
541	195 Ilorin Street	\N	 	363	49250	 	2006-02-15 04:45:30
542	193 Bhusawal Place	\N	 	539	9750	 	2006-02-15 04:45:30
543	43 Vilnius Manor	\N	 	42	79814	 	2006-02-15 04:45:30
544	183 Haiphong Street	\N	 	46	69953	 	2006-02-15 04:45:30
545	163 Augusta-Richmond County Loop	\N	 	561	33030	 	2006-02-15 04:45:30
546	191 Jos Azueta Parkway	\N	 	436	13629	 	2006-02-15 04:45:30
547	379 Lublin Parkway	\N	 	309	74568	 	2006-02-15 04:45:30
548	1658 Cuman Loop	\N	 	396	51309	 	2006-02-15 04:45:30
549	454 Qinhuangdao Drive	\N	 	68	25866	 	2006-02-15 04:45:30
550	1715 Okayama Street	\N	 	485	55676	 	2006-02-15 04:45:30
551	182 Nukualofa Drive	\N	 	275	15414	 	2006-02-15 04:45:30
552	390 Wroclaw Way	\N	 	462	5753	 	2006-02-15 04:45:30
553	1421 Quilmes Lane	\N	 	260	19151	 	2006-02-15 04:45:30
554	947 Trshavn Place	\N	 	528	841	 	2006-02-15 04:45:30
555	1764 Jalib al-Shuyukh Parkway	\N	 	459	77642	 	2006-02-15 04:45:30
556	346 Cam Ranh Avenue	\N	 	599	39976	 	2006-02-15 04:45:30
557	1407 Pachuca de Soto Place	\N	 	21	26284	 	2006-02-15 04:45:30
558	904 Clarksville Drive	\N	 	193	52234	 	2006-02-15 04:45:30
559	1917 Kumbakonam Parkway	\N	 	368	11892	 	2006-02-15 04:45:30
560	1447 Imus Place	\N	 	426	12905	 	2006-02-15 04:45:30
561	1497 Fengshan Drive	\N	 	112	63022	 	2006-02-15 04:45:30
562	869 Shikarpur Way	\N	 	496	57380	 	2006-02-15 04:45:30
563	1059 Yuncheng Avenue	\N	 	570	47498	 	2006-02-15 04:45:30
564	505 Madiun Boulevard	\N	 	577	97271	 	2006-02-15 04:45:30
565	1741 Hoshiarpur Boulevard	\N	 	79	22372	 	2006-02-15 04:45:30
566	1229 Varanasi (Benares) Manor	\N	 	43	40195	 	2006-02-15 04:45:30
567	1894 Boa Vista Way	\N	 	178	77464	 	2006-02-15 04:45:30
568	1342 Sharja Way	\N	 	488	93655	 	2006-02-15 04:45:30
569	1342 Abha Boulevard	\N	 	95	10714	 	2006-02-15 04:45:30
570	415 Pune Avenue	\N	 	580	44274	 	2006-02-15 04:45:30
571	1746 Faaa Way	\N	 	214	32515	 	2006-02-15 04:45:30
572	539 Hami Way	\N	 	538	52196	 	2006-02-15 04:45:30
573	1407 Surakarta Manor	\N	 	466	33224	 	2006-02-15 04:45:30
574	502 Mandi Bahauddin Parkway	\N	 	55	15992	 	2006-02-15 04:45:30
575	1052 Pathankot Avenue	\N	 	299	77397	 	2006-02-15 04:45:30
576	1351 Sousse Lane	\N	 	341	37815	 	2006-02-15 04:45:30
577	1501 Pangkal Pinang Avenue	\N	 	409	943	 	2006-02-15 04:45:30
578	1405 Hagonoy Avenue	\N	 	133	86587	 	2006-02-15 04:45:30
579	521 San Juan Bautista Tuxtepec Place	\N	 	598	95093	 	2006-02-15 04:45:30
580	923 Tangail Boulevard	\N	 	10	33384	 	2006-02-15 04:45:30
581	186 Skikda Lane	\N	 	131	89422	 	2006-02-15 04:45:30
582	1568 Celaya Parkway	\N	 	168	34750	 	2006-02-15 04:45:30
583	1489 Kakamigahara Lane	\N	 	526	98883	 	2006-02-15 04:45:30
584	1819 Alessandria Loop	\N	 	103	53829	 	2006-02-15 04:45:30
585	1208 Tama Loop	\N	 	344	73605	 	2006-02-15 04:45:30
586	951 Springs Lane	\N	 	219	96115	 	2006-02-15 04:45:30
587	760 Miyakonojo Drive	\N	 	246	64682	 	2006-02-15 04:45:30
588	966 Asuncin Way	\N	 	212	62703	 	2006-02-15 04:45:30
589	1584 Ljubertsy Lane	\N	 	494	22954	 	2006-02-15 04:45:30
590	247 Jining Parkway	\N	 	54	53446	 	2006-02-15 04:45:30
591	773 Dallas Manor	\N	 	424	12664	 	2006-02-15 04:45:30
592	1923 Stara Zagora Lane	\N	 	546	95179	 	2006-02-15 04:45:30
593	1402 Zanzibar Boulevard	\N	 	106	71102	 	2006-02-15 04:45:30
594	1464 Kursk Parkway	\N	 	574	17381	 	2006-02-15 04:45:30
595	1074 Sanaa Parkway	\N	 	311	22474	 	2006-02-15 04:45:30
596	1759 Niznekamsk Avenue	\N	 	14	39414	 	2006-02-15 04:45:30
597	32 Liaocheng Way	\N	 	248	1944	 	2006-02-15 04:45:30
598	42 Fontana Avenue	\N	 	512	14684	 	2006-02-15 04:45:30
599	1895 Zhezqazghan Drive	\N	 	177	36693	 	2006-02-15 04:45:30
600	1837 Kaduna Parkway	\N	 	241	82580	 	2006-02-15 04:45:30
601	844 Bucuresti Place	\N	 	242	36603	 	2006-02-15 04:45:30
602	1101 Bucuresti Boulevard	\N	 	401	97661	 	2006-02-15 04:45:30
603	1103 Quilmes Boulevard	\N	 	503	52137	 	2006-02-15 04:45:30
604	1331 Usak Boulevard	\N	 	296	61960	 	2006-02-15 04:45:30
605	1325 Fukuyama Street	\N	 	537	27107	 	2006-02-15 04:45:30
\.


--
-- Data for Name: category; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.category (category_id, name, last_update) FROM stdin;
1	Action	2006-02-15 04:46:27
2	Animation	2006-02-15 04:46:27
3	Children	2006-02-15 04:46:27
4	Classics	2006-02-15 04:46:27
5	Comedy	2006-02-15 04:46:27
6	Documentary	2006-02-15 04:46:27
7	Drama	2006-02-15 04:46:27
8	Family	2006-02-15 04:46:27
9	Foreign	2006-02-15 04:46:27
10	Games	2006-02-15 04:46:27
11	Horror	2006-02-15 04:46:27
12	Music	2006-02-15 04:46:27
13	New	2006-02-15 04:46:27
14	Sci-Fi	2006-02-15 04:46:27
15	Sports	2006-02-15 04:46:27
16	Travel	2006-02-15 04:46:27
\.


--
-- Data for Name: city; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.city (city_id, city, country_id, last_update) FROM stdin;
1	A Corua (La Corua)	87	2006-02-15 04:45:25
2	Abha	82	2006-02-15 04:45:25
3	Abu Dhabi	101	2006-02-15 04:45:25
4	Acua	60	2006-02-15 04:45:25
5	Adana	97	2006-02-15 04:45:25
6	Addis Abeba	31	2006-02-15 04:45:25
7	Aden	107	2006-02-15 04:45:25
8	Adoni	44	2006-02-15 04:45:25
9	Ahmadnagar	44	2006-02-15 04:45:25
10	Akishima	50	2006-02-15 04:45:25
11	Akron	103	2006-02-15 04:45:25
12	al-Ayn	101	2006-02-15 04:45:25
13	al-Hawiya	82	2006-02-15 04:45:25
14	al-Manama	11	2006-02-15 04:45:25
15	al-Qadarif	89	2006-02-15 04:45:25
16	al-Qatif	82	2006-02-15 04:45:25
17	Alessandria	49	2006-02-15 04:45:25
18	Allappuzha (Alleppey)	44	2006-02-15 04:45:25
19	Allende	60	2006-02-15 04:45:25
20	Almirante Brown	6	2006-02-15 04:45:25
21	Alvorada	15	2006-02-15 04:45:25
22	Ambattur	44	2006-02-15 04:45:25
23	Amersfoort	67	2006-02-15 04:45:25
24	Amroha	44	2006-02-15 04:45:25
25	Angra dos Reis	15	2006-02-15 04:45:25
26	Anpolis	15	2006-02-15 04:45:25
27	Antofagasta	22	2006-02-15 04:45:25
28	Aparecida de Goinia	15	2006-02-15 04:45:25
29	Apeldoorn	67	2006-02-15 04:45:25
30	Araatuba	15	2006-02-15 04:45:25
31	Arak	46	2006-02-15 04:45:25
32	Arecibo	77	2006-02-15 04:45:25
33	Arlington	103	2006-02-15 04:45:25
34	Ashdod	48	2006-02-15 04:45:25
35	Ashgabat	98	2006-02-15 04:45:25
36	Ashqelon	48	2006-02-15 04:45:25
37	Asuncin	73	2006-02-15 04:45:25
38	Athenai	39	2006-02-15 04:45:25
39	Atinsk	80	2006-02-15 04:45:25
40	Atlixco	60	2006-02-15 04:45:25
41	Augusta-Richmond County	103	2006-02-15 04:45:25
42	Aurora	103	2006-02-15 04:45:25
43	Avellaneda	6	2006-02-15 04:45:25
44	Bag	15	2006-02-15 04:45:25
45	Baha Blanca	6	2006-02-15 04:45:25
46	Baicheng	23	2006-02-15 04:45:25
47	Baiyin	23	2006-02-15 04:45:25
48	Baku	10	2006-02-15 04:45:25
49	Balaiha	80	2006-02-15 04:45:25
50	Balikesir	97	2006-02-15 04:45:25
51	Balurghat	44	2006-02-15 04:45:25
52	Bamenda	19	2006-02-15 04:45:25
53	Bandar Seri Begawan	16	2006-02-15 04:45:25
54	Banjul	37	2006-02-15 04:45:25
55	Barcelona	104	2006-02-15 04:45:25
56	Basel	91	2006-02-15 04:45:25
57	Bat Yam	48	2006-02-15 04:45:25
58	Batman	97	2006-02-15 04:45:25
59	Batna	2	2006-02-15 04:45:25
60	Battambang	18	2006-02-15 04:45:25
61	Baybay	75	2006-02-15 04:45:25
62	Bayugan	75	2006-02-15 04:45:25
63	Bchar	2	2006-02-15 04:45:25
64	Beira	63	2006-02-15 04:45:25
65	Bellevue	103	2006-02-15 04:45:25
66	Belm	15	2006-02-15 04:45:25
67	Benguela	4	2006-02-15 04:45:25
68	Beni-Mellal	62	2006-02-15 04:45:25
69	Benin City	69	2006-02-15 04:45:25
70	Bergamo	49	2006-02-15 04:45:25
71	Berhampore (Baharampur)	44	2006-02-15 04:45:25
72	Bern	91	2006-02-15 04:45:25
73	Bhavnagar	44	2006-02-15 04:45:25
74	Bhilwara	44	2006-02-15 04:45:25
75	Bhimavaram	44	2006-02-15 04:45:25
76	Bhopal	44	2006-02-15 04:45:25
77	Bhusawal	44	2006-02-15 04:45:25
78	Bijapur	44	2006-02-15 04:45:25
79	Bilbays	29	2006-02-15 04:45:25
80	Binzhou	23	2006-02-15 04:45:25
81	Birgunj	66	2006-02-15 04:45:25
82	Bislig	75	2006-02-15 04:45:25
83	Blumenau	15	2006-02-15 04:45:25
84	Boa Vista	15	2006-02-15 04:45:25
85	Boksburg	85	2006-02-15 04:45:25
86	Botosani	78	2006-02-15 04:45:25
87	Botshabelo	85	2006-02-15 04:45:25
88	Bradford	102	2006-02-15 04:45:25
89	Braslia	15	2006-02-15 04:45:25
90	Bratislava	84	2006-02-15 04:45:25
91	Brescia	49	2006-02-15 04:45:25
92	Brest	34	2006-02-15 04:45:25
93	Brindisi	49	2006-02-15 04:45:25
94	Brockton	103	2006-02-15 04:45:25
95	Bucuresti	78	2006-02-15 04:45:25
96	Buenaventura	24	2006-02-15 04:45:25
97	Bydgoszcz	76	2006-02-15 04:45:25
98	Cabuyao	75	2006-02-15 04:45:25
99	Callao	74	2006-02-15 04:45:25
100	Cam Ranh	105	2006-02-15 04:45:25
101	Cape Coral	103	2006-02-15 04:45:25
102	Caracas	104	2006-02-15 04:45:25
103	Carmen	60	2006-02-15 04:45:25
104	Cavite	75	2006-02-15 04:45:25
105	Cayenne	35	2006-02-15 04:45:25
106	Celaya	60	2006-02-15 04:45:25
107	Chandrapur	44	2006-02-15 04:45:25
108	Changhwa	92	2006-02-15 04:45:25
109	Changzhou	23	2006-02-15 04:45:25
110	Chapra	44	2006-02-15 04:45:25
111	Charlotte Amalie	106	2006-02-15 04:45:25
112	Chatsworth	85	2006-02-15 04:45:25
113	Cheju	86	2006-02-15 04:45:25
114	Chiayi	92	2006-02-15 04:45:25
115	Chisinau	61	2006-02-15 04:45:25
116	Chungho	92	2006-02-15 04:45:25
117	Cianjur	45	2006-02-15 04:45:25
118	Ciomas	45	2006-02-15 04:45:25
119	Ciparay	45	2006-02-15 04:45:25
120	Citrus Heights	103	2006-02-15 04:45:25
121	Citt del Vaticano	41	2006-02-15 04:45:25
122	Ciudad del Este	73	2006-02-15 04:45:25
123	Clarksville	103	2006-02-15 04:45:25
124	Coacalco de Berriozbal	60	2006-02-15 04:45:25
125	Coatzacoalcos	60	2006-02-15 04:45:25
126	Compton	103	2006-02-15 04:45:25
127	Coquimbo	22	2006-02-15 04:45:25
128	Crdoba	6	2006-02-15 04:45:25
129	Cuauhtmoc	60	2006-02-15 04:45:25
130	Cuautla	60	2006-02-15 04:45:25
131	Cuernavaca	60	2006-02-15 04:45:25
132	Cuman	104	2006-02-15 04:45:25
133	Czestochowa	76	2006-02-15 04:45:25
134	Dadu	72	2006-02-15 04:45:25
135	Dallas	103	2006-02-15 04:45:25
136	Datong	23	2006-02-15 04:45:25
137	Daugavpils	54	2006-02-15 04:45:25
138	Davao	75	2006-02-15 04:45:25
139	Daxian	23	2006-02-15 04:45:25
140	Dayton	103	2006-02-15 04:45:25
141	Deba Habe	69	2006-02-15 04:45:25
142	Denizli	97	2006-02-15 04:45:25
143	Dhaka	12	2006-02-15 04:45:25
144	Dhule (Dhulia)	44	2006-02-15 04:45:25
145	Dongying	23	2006-02-15 04:45:25
146	Donostia-San Sebastin	87	2006-02-15 04:45:25
147	Dos Quebradas	24	2006-02-15 04:45:25
148	Duisburg	38	2006-02-15 04:45:25
149	Dundee	102	2006-02-15 04:45:25
150	Dzerzinsk	80	2006-02-15 04:45:25
151	Ede	67	2006-02-15 04:45:25
152	Effon-Alaiye	69	2006-02-15 04:45:25
153	El Alto	14	2006-02-15 04:45:25
154	El Fuerte	60	2006-02-15 04:45:25
155	El Monte	103	2006-02-15 04:45:25
156	Elista	80	2006-02-15 04:45:25
157	Emeishan	23	2006-02-15 04:45:25
158	Emmen	67	2006-02-15 04:45:25
159	Enshi	23	2006-02-15 04:45:25
160	Erlangen	38	2006-02-15 04:45:25
161	Escobar	6	2006-02-15 04:45:25
162	Esfahan	46	2006-02-15 04:45:25
163	Eskisehir	97	2006-02-15 04:45:25
164	Etawah	44	2006-02-15 04:45:25
165	Ezeiza	6	2006-02-15 04:45:25
166	Ezhou	23	2006-02-15 04:45:25
167	Faaa	36	2006-02-15 04:45:25
168	Fengshan	92	2006-02-15 04:45:25
169	Firozabad	44	2006-02-15 04:45:25
170	Florencia	24	2006-02-15 04:45:25
171	Fontana	103	2006-02-15 04:45:25
172	Fukuyama	50	2006-02-15 04:45:25
173	Funafuti	99	2006-02-15 04:45:25
174	Fuyu	23	2006-02-15 04:45:25
175	Fuzhou	23	2006-02-15 04:45:25
176	Gandhinagar	44	2006-02-15 04:45:25
177	Garden Grove	103	2006-02-15 04:45:25
178	Garland	103	2006-02-15 04:45:25
179	Gatineau	20	2006-02-15 04:45:25
180	Gaziantep	97	2006-02-15 04:45:25
181	Gijn	87	2006-02-15 04:45:25
182	Gingoog	75	2006-02-15 04:45:25
183	Goinia	15	2006-02-15 04:45:25
184	Gorontalo	45	2006-02-15 04:45:25
185	Grand Prairie	103	2006-02-15 04:45:25
186	Graz	9	2006-02-15 04:45:25
187	Greensboro	103	2006-02-15 04:45:25
188	Guadalajara	60	2006-02-15 04:45:25
189	Guaruj	15	2006-02-15 04:45:25
190	guas Lindas de Gois	15	2006-02-15 04:45:25
191	Gulbarga	44	2006-02-15 04:45:25
192	Hagonoy	75	2006-02-15 04:45:25
193	Haining	23	2006-02-15 04:45:25
194	Haiphong	105	2006-02-15 04:45:25
195	Haldia	44	2006-02-15 04:45:25
196	Halifax	20	2006-02-15 04:45:25
197	Halisahar	44	2006-02-15 04:45:25
198	Halle/Saale	38	2006-02-15 04:45:25
199	Hami	23	2006-02-15 04:45:25
200	Hamilton	68	2006-02-15 04:45:25
201	Hanoi	105	2006-02-15 04:45:25
202	Hidalgo	60	2006-02-15 04:45:25
203	Higashiosaka	50	2006-02-15 04:45:25
204	Hino	50	2006-02-15 04:45:25
205	Hiroshima	50	2006-02-15 04:45:25
206	Hodeida	107	2006-02-15 04:45:25
207	Hohhot	23	2006-02-15 04:45:25
208	Hoshiarpur	44	2006-02-15 04:45:25
209	Hsichuh	92	2006-02-15 04:45:25
210	Huaian	23	2006-02-15 04:45:25
211	Hubli-Dharwad	44	2006-02-15 04:45:25
212	Huejutla de Reyes	60	2006-02-15 04:45:25
213	Huixquilucan	60	2006-02-15 04:45:25
214	Hunuco	74	2006-02-15 04:45:25
215	Ibirit	15	2006-02-15 04:45:25
216	Idfu	29	2006-02-15 04:45:25
217	Ife	69	2006-02-15 04:45:25
218	Ikerre	69	2006-02-15 04:45:25
219	Iligan	75	2006-02-15 04:45:25
220	Ilorin	69	2006-02-15 04:45:25
221	Imus	75	2006-02-15 04:45:25
222	Inegl	97	2006-02-15 04:45:25
223	Ipoh	59	2006-02-15 04:45:25
224	Isesaki	50	2006-02-15 04:45:25
225	Ivanovo	80	2006-02-15 04:45:25
226	Iwaki	50	2006-02-15 04:45:25
227	Iwakuni	50	2006-02-15 04:45:25
228	Iwatsuki	50	2006-02-15 04:45:25
229	Izumisano	50	2006-02-15 04:45:25
230	Jaffna	88	2006-02-15 04:45:25
231	Jaipur	44	2006-02-15 04:45:25
232	Jakarta	45	2006-02-15 04:45:25
233	Jalib al-Shuyukh	53	2006-02-15 04:45:25
234	Jamalpur	12	2006-02-15 04:45:25
235	Jaroslavl	80	2006-02-15 04:45:25
236	Jastrzebie-Zdrj	76	2006-02-15 04:45:25
237	Jedda	82	2006-02-15 04:45:25
238	Jelets	80	2006-02-15 04:45:25
239	Jhansi	44	2006-02-15 04:45:25
240	Jinchang	23	2006-02-15 04:45:25
241	Jining	23	2006-02-15 04:45:25
242	Jinzhou	23	2006-02-15 04:45:25
243	Jodhpur	44	2006-02-15 04:45:25
244	Johannesburg	85	2006-02-15 04:45:25
245	Joliet	103	2006-02-15 04:45:25
246	Jos Azueta	60	2006-02-15 04:45:25
247	Juazeiro do Norte	15	2006-02-15 04:45:25
248	Juiz de Fora	15	2006-02-15 04:45:25
249	Junan	23	2006-02-15 04:45:25
250	Jurez	60	2006-02-15 04:45:25
251	Kabul	1	2006-02-15 04:45:25
252	Kaduna	69	2006-02-15 04:45:25
253	Kakamigahara	50	2006-02-15 04:45:25
254	Kaliningrad	80	2006-02-15 04:45:25
255	Kalisz	76	2006-02-15 04:45:25
256	Kamakura	50	2006-02-15 04:45:25
257	Kamarhati	44	2006-02-15 04:45:25
258	Kamjanets-Podilskyi	100	2006-02-15 04:45:25
259	Kamyin	80	2006-02-15 04:45:25
260	Kanazawa	50	2006-02-15 04:45:25
261	Kanchrapara	44	2006-02-15 04:45:25
262	Kansas City	103	2006-02-15 04:45:25
263	Karnal	44	2006-02-15 04:45:25
264	Katihar	44	2006-02-15 04:45:25
265	Kermanshah	46	2006-02-15 04:45:25
266	Kilis	97	2006-02-15 04:45:25
267	Kimberley	85	2006-02-15 04:45:25
268	Kimchon	86	2006-02-15 04:45:25
269	Kingstown	81	2006-02-15 04:45:25
270	Kirovo-Tepetsk	80	2006-02-15 04:45:25
271	Kisumu	52	2006-02-15 04:45:25
272	Kitwe	109	2006-02-15 04:45:25
273	Klerksdorp	85	2006-02-15 04:45:25
274	Kolpino	80	2006-02-15 04:45:25
275	Konotop	100	2006-02-15 04:45:25
276	Koriyama	50	2006-02-15 04:45:25
277	Korla	23	2006-02-15 04:45:25
278	Korolev	80	2006-02-15 04:45:25
279	Kowloon and New Kowloon	42	2006-02-15 04:45:25
280	Kragujevac	108	2006-02-15 04:45:25
281	Ktahya	97	2006-02-15 04:45:25
282	Kuching	59	2006-02-15 04:45:25
283	Kumbakonam	44	2006-02-15 04:45:25
284	Kurashiki	50	2006-02-15 04:45:25
285	Kurgan	80	2006-02-15 04:45:25
286	Kursk	80	2006-02-15 04:45:25
287	Kuwana	50	2006-02-15 04:45:25
288	La Paz	60	2006-02-15 04:45:25
289	La Plata	6	2006-02-15 04:45:25
290	La Romana	27	2006-02-15 04:45:25
291	Laiwu	23	2006-02-15 04:45:25
292	Lancaster	103	2006-02-15 04:45:25
293	Laohekou	23	2006-02-15 04:45:25
294	Lapu-Lapu	75	2006-02-15 04:45:25
295	Laredo	103	2006-02-15 04:45:25
296	Lausanne	91	2006-02-15 04:45:25
297	Le Mans	34	2006-02-15 04:45:25
298	Lengshuijiang	23	2006-02-15 04:45:25
299	Leshan	23	2006-02-15 04:45:25
300	Lethbridge	20	2006-02-15 04:45:25
301	Lhokseumawe	45	2006-02-15 04:45:25
302	Liaocheng	23	2006-02-15 04:45:25
303	Liepaja	54	2006-02-15 04:45:25
304	Lilongwe	58	2006-02-15 04:45:25
305	Lima	74	2006-02-15 04:45:25
306	Lincoln	103	2006-02-15 04:45:25
307	Linz	9	2006-02-15 04:45:25
308	Lipetsk	80	2006-02-15 04:45:25
309	Livorno	49	2006-02-15 04:45:25
310	Ljubertsy	80	2006-02-15 04:45:25
311	Loja	28	2006-02-15 04:45:25
312	London	102	2006-02-15 04:45:25
313	London	20	2006-02-15 04:45:25
314	Lublin	76	2006-02-15 04:45:25
315	Lubumbashi	25	2006-02-15 04:45:25
316	Lungtan	92	2006-02-15 04:45:25
317	Luzinia	15	2006-02-15 04:45:25
318	Madiun	45	2006-02-15 04:45:25
319	Mahajanga	57	2006-02-15 04:45:25
320	Maikop	80	2006-02-15 04:45:25
321	Malm	90	2006-02-15 04:45:25
322	Manchester	103	2006-02-15 04:45:25
323	Mandaluyong	75	2006-02-15 04:45:25
324	Mandi Bahauddin	72	2006-02-15 04:45:25
325	Mannheim	38	2006-02-15 04:45:25
326	Maracabo	104	2006-02-15 04:45:25
327	Mardan	72	2006-02-15 04:45:25
328	Maring	15	2006-02-15 04:45:25
329	Masqat	71	2006-02-15 04:45:25
330	Matamoros	60	2006-02-15 04:45:25
331	Matsue	50	2006-02-15 04:45:25
332	Meixian	23	2006-02-15 04:45:25
333	Memphis	103	2006-02-15 04:45:25
334	Merlo	6	2006-02-15 04:45:25
335	Mexicali	60	2006-02-15 04:45:25
336	Miraj	44	2006-02-15 04:45:25
337	Mit Ghamr	29	2006-02-15 04:45:25
338	Miyakonojo	50	2006-02-15 04:45:25
339	Mogiljov	13	2006-02-15 04:45:25
340	Molodetno	13	2006-02-15 04:45:25
341	Monclova	60	2006-02-15 04:45:25
342	Monywa	64	2006-02-15 04:45:25
343	Moscow	80	2006-02-15 04:45:25
344	Mosul	47	2006-02-15 04:45:25
345	Mukateve	100	2006-02-15 04:45:25
346	Munger (Monghyr)	44	2006-02-15 04:45:25
347	Mwanza	93	2006-02-15 04:45:25
348	Mwene-Ditu	25	2006-02-15 04:45:25
349	Myingyan	64	2006-02-15 04:45:25
350	Mysore	44	2006-02-15 04:45:25
351	Naala-Porto	63	2006-02-15 04:45:25
352	Nabereznyje Telny	80	2006-02-15 04:45:25
353	Nador	62	2006-02-15 04:45:25
354	Nagaon	44	2006-02-15 04:45:25
355	Nagareyama	50	2006-02-15 04:45:25
356	Najafabad	46	2006-02-15 04:45:25
357	Naju	86	2006-02-15 04:45:25
358	Nakhon Sawan	94	2006-02-15 04:45:25
359	Nam Dinh	105	2006-02-15 04:45:25
360	Namibe	4	2006-02-15 04:45:25
361	Nantou	92	2006-02-15 04:45:25
362	Nanyang	23	2006-02-15 04:45:25
363	NDjamna	21	2006-02-15 04:45:25
364	Newcastle	85	2006-02-15 04:45:25
365	Nezahualcyotl	60	2006-02-15 04:45:25
366	Nha Trang	105	2006-02-15 04:45:25
367	Niznekamsk	80	2006-02-15 04:45:25
368	Novi Sad	108	2006-02-15 04:45:25
369	Novoterkassk	80	2006-02-15 04:45:25
370	Nukualofa	95	2006-02-15 04:45:25
371	Nuuk	40	2006-02-15 04:45:25
372	Nyeri	52	2006-02-15 04:45:25
373	Ocumare del Tuy	104	2006-02-15 04:45:25
374	Ogbomosho	69	2006-02-15 04:45:25
375	Okara	72	2006-02-15 04:45:25
376	Okayama	50	2006-02-15 04:45:25
377	Okinawa	50	2006-02-15 04:45:25
378	Olomouc	26	2006-02-15 04:45:25
379	Omdurman	89	2006-02-15 04:45:25
380	Omiya	50	2006-02-15 04:45:25
381	Ondo	69	2006-02-15 04:45:25
382	Onomichi	50	2006-02-15 04:45:25
383	Oshawa	20	2006-02-15 04:45:25
384	Osmaniye	97	2006-02-15 04:45:25
385	ostka	100	2006-02-15 04:45:25
386	Otsu	50	2006-02-15 04:45:25
387	Oulu	33	2006-02-15 04:45:25
388	Ourense (Orense)	87	2006-02-15 04:45:25
389	Owo	69	2006-02-15 04:45:25
390	Oyo	69	2006-02-15 04:45:25
391	Ozamis	75	2006-02-15 04:45:25
392	Paarl	85	2006-02-15 04:45:25
393	Pachuca de Soto	60	2006-02-15 04:45:25
394	Pak Kret	94	2006-02-15 04:45:25
395	Palghat (Palakkad)	44	2006-02-15 04:45:25
396	Pangkal Pinang	45	2006-02-15 04:45:25
397	Papeete	36	2006-02-15 04:45:25
398	Parbhani	44	2006-02-15 04:45:25
399	Pathankot	44	2006-02-15 04:45:25
400	Patiala	44	2006-02-15 04:45:25
401	Patras	39	2006-02-15 04:45:25
402	Pavlodar	51	2006-02-15 04:45:25
403	Pemalang	45	2006-02-15 04:45:25
404	Peoria	103	2006-02-15 04:45:25
405	Pereira	24	2006-02-15 04:45:25
406	Phnom Penh	18	2006-02-15 04:45:25
407	Pingxiang	23	2006-02-15 04:45:25
408	Pjatigorsk	80	2006-02-15 04:45:25
409	Plock	76	2006-02-15 04:45:25
410	Po	15	2006-02-15 04:45:25
411	Ponce	77	2006-02-15 04:45:25
412	Pontianak	45	2006-02-15 04:45:25
413	Poos de Caldas	15	2006-02-15 04:45:25
414	Portoviejo	28	2006-02-15 04:45:25
415	Probolinggo	45	2006-02-15 04:45:25
416	Pudukkottai	44	2006-02-15 04:45:25
417	Pune	44	2006-02-15 04:45:25
418	Purnea (Purnia)	44	2006-02-15 04:45:25
419	Purwakarta	45	2006-02-15 04:45:25
420	Pyongyang	70	2006-02-15 04:45:25
421	Qalyub	29	2006-02-15 04:45:25
422	Qinhuangdao	23	2006-02-15 04:45:25
423	Qomsheh	46	2006-02-15 04:45:25
424	Quilmes	6	2006-02-15 04:45:25
425	Rae Bareli	44	2006-02-15 04:45:25
426	Rajkot	44	2006-02-15 04:45:25
427	Rampur	44	2006-02-15 04:45:25
428	Rancagua	22	2006-02-15 04:45:25
429	Ranchi	44	2006-02-15 04:45:25
430	Richmond Hill	20	2006-02-15 04:45:25
431	Rio Claro	15	2006-02-15 04:45:25
432	Rizhao	23	2006-02-15 04:45:25
433	Roanoke	103	2006-02-15 04:45:25
434	Robamba	28	2006-02-15 04:45:25
435	Rockford	103	2006-02-15 04:45:25
436	Ruse	17	2006-02-15 04:45:25
437	Rustenburg	85	2006-02-15 04:45:25
438	s-Hertogenbosch	67	2006-02-15 04:45:25
439	Saarbrcken	38	2006-02-15 04:45:25
440	Sagamihara	50	2006-02-15 04:45:25
441	Saint Louis	103	2006-02-15 04:45:25
442	Saint-Denis	79	2006-02-15 04:45:25
443	Sal	62	2006-02-15 04:45:25
444	Salala	71	2006-02-15 04:45:25
445	Salamanca	60	2006-02-15 04:45:25
446	Salinas	103	2006-02-15 04:45:25
447	Salzburg	9	2006-02-15 04:45:25
448	Sambhal	44	2006-02-15 04:45:25
449	San Bernardino	103	2006-02-15 04:45:25
450	San Felipe de Puerto Plata	27	2006-02-15 04:45:25
451	San Felipe del Progreso	60	2006-02-15 04:45:25
452	San Juan Bautista Tuxtepec	60	2006-02-15 04:45:25
453	San Lorenzo	73	2006-02-15 04:45:25
454	San Miguel de Tucumn	6	2006-02-15 04:45:25
455	Sanaa	107	2006-02-15 04:45:25
456	Santa Brbara dOeste	15	2006-02-15 04:45:25
457	Santa F	6	2006-02-15 04:45:25
458	Santa Rosa	75	2006-02-15 04:45:25
459	Santiago de Compostela	87	2006-02-15 04:45:25
460	Santiago de los Caballeros	27	2006-02-15 04:45:25
461	Santo Andr	15	2006-02-15 04:45:25
462	Sanya	23	2006-02-15 04:45:25
463	Sasebo	50	2006-02-15 04:45:25
464	Satna	44	2006-02-15 04:45:25
465	Sawhaj	29	2006-02-15 04:45:25
466	Serpuhov	80	2006-02-15 04:45:25
467	Shahr-e Kord	46	2006-02-15 04:45:25
468	Shanwei	23	2006-02-15 04:45:25
469	Shaoguan	23	2006-02-15 04:45:25
470	Sharja	101	2006-02-15 04:45:25
471	Shenzhen	23	2006-02-15 04:45:25
472	Shikarpur	72	2006-02-15 04:45:25
473	Shimoga	44	2006-02-15 04:45:25
474	Shimonoseki	50	2006-02-15 04:45:25
475	Shivapuri	44	2006-02-15 04:45:25
476	Shubra al-Khayma	29	2006-02-15 04:45:25
477	Siegen	38	2006-02-15 04:45:25
478	Siliguri (Shiliguri)	44	2006-02-15 04:45:25
479	Simferopol	100	2006-02-15 04:45:25
480	Sincelejo	24	2006-02-15 04:45:25
481	Sirjan	46	2006-02-15 04:45:25
482	Sivas	97	2006-02-15 04:45:25
483	Skikda	2	2006-02-15 04:45:25
484	Smolensk	80	2006-02-15 04:45:25
485	So Bernardo do Campo	15	2006-02-15 04:45:25
486	So Leopoldo	15	2006-02-15 04:45:25
487	Sogamoso	24	2006-02-15 04:45:25
488	Sokoto	69	2006-02-15 04:45:25
489	Songkhla	94	2006-02-15 04:45:25
490	Sorocaba	15	2006-02-15 04:45:25
491	Soshanguve	85	2006-02-15 04:45:25
492	Sousse	96	2006-02-15 04:45:25
493	South Hill	5	2006-02-15 04:45:25
494	Southampton	102	2006-02-15 04:45:25
495	Southend-on-Sea	102	2006-02-15 04:45:25
496	Southport	102	2006-02-15 04:45:25
497	Springs	85	2006-02-15 04:45:25
498	Stara Zagora	17	2006-02-15 04:45:25
499	Sterling Heights	103	2006-02-15 04:45:25
500	Stockport	102	2006-02-15 04:45:25
501	Sucre	14	2006-02-15 04:45:25
502	Suihua	23	2006-02-15 04:45:25
503	Sullana	74	2006-02-15 04:45:25
504	Sultanbeyli	97	2006-02-15 04:45:25
505	Sumqayit	10	2006-02-15 04:45:25
506	Sumy	100	2006-02-15 04:45:25
507	Sungai Petani	59	2006-02-15 04:45:25
508	Sunnyvale	103	2006-02-15 04:45:25
509	Surakarta	45	2006-02-15 04:45:25
510	Syktyvkar	80	2006-02-15 04:45:25
511	Syrakusa	49	2006-02-15 04:45:25
512	Szkesfehrvr	43	2006-02-15 04:45:25
513	Tabora	93	2006-02-15 04:45:25
514	Tabriz	46	2006-02-15 04:45:25
515	Tabuk	82	2006-02-15 04:45:25
516	Tafuna	3	2006-02-15 04:45:25
517	Taguig	75	2006-02-15 04:45:25
518	Taizz	107	2006-02-15 04:45:25
519	Talavera	75	2006-02-15 04:45:25
520	Tallahassee	103	2006-02-15 04:45:25
521	Tama	50	2006-02-15 04:45:25
522	Tambaram	44	2006-02-15 04:45:25
523	Tanauan	75	2006-02-15 04:45:25
524	Tandil	6	2006-02-15 04:45:25
525	Tangail	12	2006-02-15 04:45:25
526	Tanshui	92	2006-02-15 04:45:25
527	Tanza	75	2006-02-15 04:45:25
528	Tarlac	75	2006-02-15 04:45:25
529	Tarsus	97	2006-02-15 04:45:25
530	Tartu	30	2006-02-15 04:45:25
531	Teboksary	80	2006-02-15 04:45:25
532	Tegal	45	2006-02-15 04:45:25
533	Tel Aviv-Jaffa	48	2006-02-15 04:45:25
534	Tete	63	2006-02-15 04:45:25
535	Tianjin	23	2006-02-15 04:45:25
536	Tiefa	23	2006-02-15 04:45:25
537	Tieli	23	2006-02-15 04:45:25
538	Tokat	97	2006-02-15 04:45:25
539	Tonghae	86	2006-02-15 04:45:25
540	Tongliao	23	2006-02-15 04:45:25
541	Torren	60	2006-02-15 04:45:25
542	Touliu	92	2006-02-15 04:45:25
543	Toulon	34	2006-02-15 04:45:25
544	Toulouse	34	2006-02-15 04:45:25
545	Trshavn	32	2006-02-15 04:45:25
546	Tsaotun	92	2006-02-15 04:45:25
547	Tsuyama	50	2006-02-15 04:45:25
548	Tuguegarao	75	2006-02-15 04:45:25
549	Tychy	76	2006-02-15 04:45:25
550	Udaipur	44	2006-02-15 04:45:25
551	Udine	49	2006-02-15 04:45:25
552	Ueda	50	2006-02-15 04:45:25
553	Uijongbu	86	2006-02-15 04:45:25
554	Uluberia	44	2006-02-15 04:45:25
555	Urawa	50	2006-02-15 04:45:25
556	Uruapan	60	2006-02-15 04:45:25
557	Usak	97	2006-02-15 04:45:25
558	Usolje-Sibirskoje	80	2006-02-15 04:45:25
559	Uttarpara-Kotrung	44	2006-02-15 04:45:25
560	Vaduz	55	2006-02-15 04:45:25
561	Valencia	104	2006-02-15 04:45:25
562	Valle de la Pascua	104	2006-02-15 04:45:25
563	Valle de Santiago	60	2006-02-15 04:45:25
564	Valparai	44	2006-02-15 04:45:25
565	Vancouver	20	2006-02-15 04:45:25
566	Varanasi (Benares)	44	2006-02-15 04:45:25
567	Vicente Lpez	6	2006-02-15 04:45:25
568	Vijayawada	44	2006-02-15 04:45:25
569	Vila Velha	15	2006-02-15 04:45:25
570	Vilnius	56	2006-02-15 04:45:25
571	Vinh	105	2006-02-15 04:45:25
572	Vitria de Santo Anto	15	2006-02-15 04:45:25
573	Warren	103	2006-02-15 04:45:25
574	Weifang	23	2006-02-15 04:45:25
575	Witten	38	2006-02-15 04:45:25
576	Woodridge	8	2006-02-15 04:45:25
577	Wroclaw	76	2006-02-15 04:45:25
578	Xiangfan	23	2006-02-15 04:45:25
579	Xiangtan	23	2006-02-15 04:45:25
580	Xintai	23	2006-02-15 04:45:25
581	Xinxiang	23	2006-02-15 04:45:25
582	Yamuna Nagar	44	2006-02-15 04:45:25
583	Yangor	65	2006-02-15 04:45:25
584	Yantai	23	2006-02-15 04:45:25
585	Yaound	19	2006-02-15 04:45:25
586	Yerevan	7	2006-02-15 04:45:25
587	Yinchuan	23	2006-02-15 04:45:25
588	Yingkou	23	2006-02-15 04:45:25
589	York	102	2006-02-15 04:45:25
590	Yuncheng	23	2006-02-15 04:45:25
591	Yuzhou	23	2006-02-15 04:45:25
592	Zalantun	23	2006-02-15 04:45:25
593	Zanzibar	93	2006-02-15 04:45:25
594	Zaoyang	23	2006-02-15 04:45:25
595	Zapopan	60	2006-02-15 04:45:25
596	Zaria	69	2006-02-15 04:45:25
597	Zeleznogorsk	80	2006-02-15 04:45:25
598	Zhezqazghan	51	2006-02-15 04:45:25
599	Zhoushan	23	2006-02-15 04:45:25
600	Ziguinchor	83	2006-02-15 04:45:25
\.


--
-- Data for Name: country; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.country (country_id, country, last_update) FROM stdin;
1	Afghanistan	2006-02-15 04:44:00
2	Algeria	2006-02-15 04:44:00
3	American Samoa	2006-02-15 04:44:00
4	Angola	2006-02-15 04:44:00
5	Anguilla	2006-02-15 04:44:00
6	Argentina	2006-02-15 04:44:00
7	Armenia	2006-02-15 04:44:00
8	Australia	2006-02-15 04:44:00
9	Austria	2006-02-15 04:44:00
10	Azerbaijan	2006-02-15 04:44:00
11	Bahrain	2006-02-15 04:44:00
12	Bangladesh	2006-02-15 04:44:00
13	Belarus	2006-02-15 04:44:00
14	Bolivia	2006-02-15 04:44:00
15	Brazil	2006-02-15 04:44:00
16	Brunei	2006-02-15 04:44:00
17	Bulgaria	2006-02-15 04:44:00
18	Cambodia	2006-02-15 04:44:00
19	Cameroon	2006-02-15 04:44:00
20	Canada	2006-02-15 04:44:00
21	Chad	2006-02-15 04:44:00
22	Chile	2006-02-15 04:44:00
23	China	2006-02-15 04:44:00
24	Colombia	2006-02-15 04:44:00
25	Congo, The Democratic Republic of the	2006-02-15 04:44:00
26	Czech Republic	2006-02-15 04:44:00
27	Dominican Republic	2006-02-15 04:44:00
28	Ecuador	2006-02-15 04:44:00
29	Egypt	2006-02-15 04:44:00
30	Estonia	2006-02-15 04:44:00
31	Ethiopia	2006-02-15 04:44:00
32	Faroe Islands	2006-02-15 04:44:00
33	Finland	2006-02-15 04:44:00
34	France	2006-02-15 04:44:00
35	French Guiana	2006-02-15 04:44:00
36	French Polynesia	2006-02-15 04:44:00
37	Gambia	2006-02-15 04:44:00
38	Germany	2006-02-15 04:44:00
39	Greece	2006-02-15 04:44:00
40	Greenland	2006-02-15 04:44:00
41	Holy See (Vatican City State)	2006-02-15 04:44:00
42	Hong Kong	2006-02-15 04:44:00
43	Hungary	2006-02-15 04:44:00
44	India	2006-02-15 04:44:00
45	Indonesia	2006-02-15 04:44:00
46	Iran	2006-02-15 04:44:00
47	Iraq	2006-02-15 04:44:00
48	Israel	2006-02-15 04:44:00
49	Italy	2006-02-15 04:44:00
50	Japan	2006-02-15 04:44:00
51	Kazakstan	2006-02-15 04:44:00
52	Kenya	2006-02-15 04:44:00
53	Kuwait	2006-02-15 04:44:00
54	Latvia	2006-02-15 04:44:00
55	Liechtenstein	2006-02-15 04:44:00
56	Lithuania	2006-02-15 04:44:00
57	Madagascar	2006-02-15 04:44:00
58	Malawi	2006-02-15 04:44:00
59	Malaysia	2006-02-15 04:44:00
60	Mexico	2006-02-15 04:44:00
61	Moldova	2006-02-15 04:44:00
62	Morocco	2006-02-15 04:44:00
63	Mozambique	2006-02-15 04:44:00
64	Myanmar	2006-02-15 04:44:00
65	Nauru	2006-02-15 04:44:00
66	Nepal	2006-02-15 04:44:00
67	Netherlands	2006-02-15 04:44:00
68	New Zealand	2006-02-15 04:44:00
69	Nigeria	2006-02-15 04:44:00
70	North Korea	2006-02-15 04:44:00
71	Oman	2006-02-15 04:44:00
72	Pakistan	2006-02-15 04:44:00
73	Paraguay	2006-02-15 04:44:00
74	Peru	2006-02-15 04:44:00
75	Philippines	2006-02-15 04:44:00
76	Poland	2006-02-15 04:44:00
77	Puerto Rico	2006-02-15 04:44:00
78	Romania	2006-02-15 04:44:00
79	Runion	2006-02-15 04:44:00
80	Russian Federation	2006-02-15 04:44:00
81	Saint Vincent and the Grenadines	2006-02-15 04:44:00
82	Saudi Arabia	2006-02-15 04:44:00
83	Senegal	2006-02-15 04:44:00
84	Slovakia	2006-02-15 04:44:00
85	South Africa	2006-02-15 04:44:00
86	South Korea	2006-02-15 04:44:00
87	Spain	2006-02-15 04:44:00
88	Sri Lanka	2006-02-15 04:44:00
89	Sudan	2006-02-15 04:44:00
90	Sweden	2006-02-15 04:44:00
91	Switzerland	2006-02-15 04:44:00
92	Taiwan	2006-02-15 04:44:00
93	Tanzania	2006-02-15 04:44:00
94	Thailand	2006-02-15 04:44:00
95	Tonga	2006-02-15 04:44:00
96	Tunisia	2006-02-15 04:44:00
97	Turkey	2006-02-15 04:44:00
98	Turkmenistan	2006-02-15 04:44:00
99	Tuvalu	2006-02-15 04:44:00
100	Ukraine	2006-02-15 04:44:00
101	United Arab Emirates	2006-02-15 04:44:00
102	United Kingdom	2006-02-15 04:44:00
103	United States	2006-02-15 04:44:00
104	Venezuela	2006-02-15 04:44:00
105	Vietnam	2006-02-15 04:44:00
106	Virgin Islands, U.S.	2006-02-15 04:44:00
107	Yemen	2006-02-15 04:44:00
108	Yugoslavia	2006-02-15 04:44:00
109	Zambia	2006-02-15 04:44:00
\.


--
-- Data for Name: customer; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.customer (customer_id, store_id, first_name, last_name, email, address_id, activebool, create_date, last_update, active) FROM stdin;
1	1	MARY	SMITH	MARY.SMITH@sakilacustomer.org	5	t	2006-02-14	2006-02-15 04:57:20	1
2	1	PATRICIA	JOHNSON	PATRICIA.JOHNSON@sakilacustomer.org	6	t	2006-02-14	2006-02-15 04:57:20	1
3	1	LINDA	WILLIAMS	LINDA.WILLIAMS@sakilacustomer.org	7	t	2006-02-14	2006-02-15 04:57:20	1
4	2	BARBARA	JONES	BARBARA.JONES@sakilacustomer.org	8	t	2006-02-14	2006-02-15 04:57:20	1
5	1	ELIZABETH	BROWN	ELIZABETH.BROWN@sakilacustomer.org	9	t	2006-02-14	2006-02-15 04:57:20	1
6	2	JENNIFER	DAVIS	JENNIFER.DAVIS@sakilacustomer.org	10	t	2006-02-14	2006-02-15 04:57:20	1
7	1	MARIA	MILLER	MARIA.MILLER@sakilacustomer.org	11	t	2006-02-14	2006-02-15 04:57:20	1
8	2	SUSAN	WILSON	SUSAN.WILSON@sakilacustomer.org	12	t	2006-02-14	2006-02-15 04:57:20	1
9	2	MARGARET	MOORE	MARGARET.MOORE@sakilacustomer.org	13	t	2006-02-14	2006-02-15 04:57:20	1
10	1	DOROTHY	TAYLOR	DOROTHY.TAYLOR@sakilacustomer.org	14	t	2006-02-14	2006-02-15 04:57:20	1
11	2	LISA	ANDERSON	LISA.ANDERSON@sakilacustomer.org	15	t	2006-02-14	2006-02-15 04:57:20	1
12	1	NANCY	THOMAS	NANCY.THOMAS@sakilacustomer.org	16	t	2006-02-14	2006-02-15 04:57:20	1
13	2	KAREN	JACKSON	KAREN.JACKSON@sakilacustomer.org	17	t	2006-02-14	2006-02-15 04:57:20	1
14	2	BETTY	WHITE	BETTY.WHITE@sakilacustomer.org	18	t	2006-02-14	2006-02-15 04:57:20	1
15	1	HELEN	HARRIS	HELEN.HARRIS@sakilacustomer.org	19	t	2006-02-14	2006-02-15 04:57:20	1
16	2	SANDRA	MARTIN	SANDRA.MARTIN@sakilacustomer.org	20	t	2006-02-14	2006-02-15 04:57:20	0
17	1	DONNA	THOMPSON	DONNA.THOMPSON@sakilacustomer.org	21	t	2006-02-14	2006-02-15 04:57:20	1
18	2	CAROL	GARCIA	CAROL.GARCIA@sakilacustomer.org	22	t	2006-02-14	2006-02-15 04:57:20	1
19	1	RUTH	MARTINEZ	RUTH.MARTINEZ@sakilacustomer.org	23	t	2006-02-14	2006-02-15 04:57:20	1
20	2	SHARON	ROBINSON	SHARON.ROBINSON@sakilacustomer.org	24	t	2006-02-14	2006-02-15 04:57:20	1
21	1	MICHELLE	CLARK	MICHELLE.CLARK@sakilacustomer.org	25	t	2006-02-14	2006-02-15 04:57:20	1
22	1	LAURA	RODRIGUEZ	LAURA.RODRIGUEZ@sakilacustomer.org	26	t	2006-02-14	2006-02-15 04:57:20	1
23	2	SARAH	LEWIS	SARAH.LEWIS@sakilacustomer.org	27	t	2006-02-14	2006-02-15 04:57:20	1
24	2	KIMBERLY	LEE	KIMBERLY.LEE@sakilacustomer.org	28	t	2006-02-14	2006-02-15 04:57:20	1
25	1	DEBORAH	WALKER	DEBORAH.WALKER@sakilacustomer.org	29	t	2006-02-14	2006-02-15 04:57:20	1
26	2	JESSICA	HALL	JESSICA.HALL@sakilacustomer.org	30	t	2006-02-14	2006-02-15 04:57:20	1
27	2	SHIRLEY	ALLEN	SHIRLEY.ALLEN@sakilacustomer.org	31	t	2006-02-14	2006-02-15 04:57:20	1
28	1	CYNTHIA	YOUNG	CYNTHIA.YOUNG@sakilacustomer.org	32	t	2006-02-14	2006-02-15 04:57:20	1
29	2	ANGELA	HERNANDEZ	ANGELA.HERNANDEZ@sakilacustomer.org	33	t	2006-02-14	2006-02-15 04:57:20	1
30	1	MELISSA	KING	MELISSA.KING@sakilacustomer.org	34	t	2006-02-14	2006-02-15 04:57:20	1
31	2	BRENDA	WRIGHT	BRENDA.WRIGHT@sakilacustomer.org	35	t	2006-02-14	2006-02-15 04:57:20	1
32	1	AMY	LOPEZ	AMY.LOPEZ@sakilacustomer.org	36	t	2006-02-14	2006-02-15 04:57:20	1
33	2	ANNA	HILL	ANNA.HILL@sakilacustomer.org	37	t	2006-02-14	2006-02-15 04:57:20	1
34	2	REBECCA	SCOTT	REBECCA.SCOTT@sakilacustomer.org	38	t	2006-02-14	2006-02-15 04:57:20	1
35	2	VIRGINIA	GREEN	VIRGINIA.GREEN@sakilacustomer.org	39	t	2006-02-14	2006-02-15 04:57:20	1
36	2	KATHLEEN	ADAMS	KATHLEEN.ADAMS@sakilacustomer.org	40	t	2006-02-14	2006-02-15 04:57:20	1
37	1	PAMELA	BAKER	PAMELA.BAKER@sakilacustomer.org	41	t	2006-02-14	2006-02-15 04:57:20	1
38	1	MARTHA	GONZALEZ	MARTHA.GONZALEZ@sakilacustomer.org	42	t	2006-02-14	2006-02-15 04:57:20	1
39	1	DEBRA	NELSON	DEBRA.NELSON@sakilacustomer.org	43	t	2006-02-14	2006-02-15 04:57:20	1
40	2	AMANDA	CARTER	AMANDA.CARTER@sakilacustomer.org	44	t	2006-02-14	2006-02-15 04:57:20	1
41	1	STEPHANIE	MITCHELL	STEPHANIE.MITCHELL@sakilacustomer.org	45	t	2006-02-14	2006-02-15 04:57:20	1
42	2	CAROLYN	PEREZ	CAROLYN.PEREZ@sakilacustomer.org	46	t	2006-02-14	2006-02-15 04:57:20	1
43	2	CHRISTINE	ROBERTS	CHRISTINE.ROBERTS@sakilacustomer.org	47	t	2006-02-14	2006-02-15 04:57:20	1
44	1	MARIE	TURNER	MARIE.TURNER@sakilacustomer.org	48	t	2006-02-14	2006-02-15 04:57:20	1
45	1	JANET	PHILLIPS	JANET.PHILLIPS@sakilacustomer.org	49	t	2006-02-14	2006-02-15 04:57:20	1
46	2	CATHERINE	CAMPBELL	CATHERINE.CAMPBELL@sakilacustomer.org	50	t	2006-02-14	2006-02-15 04:57:20	1
47	1	FRANCES	PARKER	FRANCES.PARKER@sakilacustomer.org	51	t	2006-02-14	2006-02-15 04:57:20	1
48	1	ANN	EVANS	ANN.EVANS@sakilacustomer.org	52	t	2006-02-14	2006-02-15 04:57:20	1
49	2	JOYCE	EDWARDS	JOYCE.EDWARDS@sakilacustomer.org	53	t	2006-02-14	2006-02-15 04:57:20	1
50	1	DIANE	COLLINS	DIANE.COLLINS@sakilacustomer.org	54	t	2006-02-14	2006-02-15 04:57:20	1
51	1	ALICE	STEWART	ALICE.STEWART@sakilacustomer.org	55	t	2006-02-14	2006-02-15 04:57:20	1
52	1	JULIE	SANCHEZ	JULIE.SANCHEZ@sakilacustomer.org	56	t	2006-02-14	2006-02-15 04:57:20	1
53	1	HEATHER	MORRIS	HEATHER.MORRIS@sakilacustomer.org	57	t	2006-02-14	2006-02-15 04:57:20	1
54	1	TERESA	ROGERS	TERESA.ROGERS@sakilacustomer.org	58	t	2006-02-14	2006-02-15 04:57:20	1
55	2	DORIS	REED	DORIS.REED@sakilacustomer.org	59	t	2006-02-14	2006-02-15 04:57:20	1
56	1	GLORIA	COOK	GLORIA.COOK@sakilacustomer.org	60	t	2006-02-14	2006-02-15 04:57:20	1
57	2	EVELYN	MORGAN	EVELYN.MORGAN@sakilacustomer.org	61	t	2006-02-14	2006-02-15 04:57:20	1
58	1	JEAN	BELL	JEAN.BELL@sakilacustomer.org	62	t	2006-02-14	2006-02-15 04:57:20	1
59	1	CHERYL	MURPHY	CHERYL.MURPHY@sakilacustomer.org	63	t	2006-02-14	2006-02-15 04:57:20	1
60	1	MILDRED	BAILEY	MILDRED.BAILEY@sakilacustomer.org	64	t	2006-02-14	2006-02-15 04:57:20	1
61	2	KATHERINE	RIVERA	KATHERINE.RIVERA@sakilacustomer.org	65	t	2006-02-14	2006-02-15 04:57:20	1
62	1	JOAN	COOPER	JOAN.COOPER@sakilacustomer.org	66	t	2006-02-14	2006-02-15 04:57:20	1
63	1	ASHLEY	RICHARDSON	ASHLEY.RICHARDSON@sakilacustomer.org	67	t	2006-02-14	2006-02-15 04:57:20	1
64	2	JUDITH	COX	JUDITH.COX@sakilacustomer.org	68	t	2006-02-14	2006-02-15 04:57:20	0
65	2	ROSE	HOWARD	ROSE.HOWARD@sakilacustomer.org	69	t	2006-02-14	2006-02-15 04:57:20	1
66	2	JANICE	WARD	JANICE.WARD@sakilacustomer.org	70	t	2006-02-14	2006-02-15 04:57:20	1
67	1	KELLY	TORRES	KELLY.TORRES@sakilacustomer.org	71	t	2006-02-14	2006-02-15 04:57:20	1
68	1	NICOLE	PETERSON	NICOLE.PETERSON@sakilacustomer.org	72	t	2006-02-14	2006-02-15 04:57:20	1
69	2	JUDY	GRAY	JUDY.GRAY@sakilacustomer.org	73	t	2006-02-14	2006-02-15 04:57:20	1
70	2	CHRISTINA	RAMIREZ	CHRISTINA.RAMIREZ@sakilacustomer.org	74	t	2006-02-14	2006-02-15 04:57:20	1
71	1	KATHY	JAMES	KATHY.JAMES@sakilacustomer.org	75	t	2006-02-14	2006-02-15 04:57:20	1
72	2	THERESA	WATSON	THERESA.WATSON@sakilacustomer.org	76	t	2006-02-14	2006-02-15 04:57:20	1
73	2	BEVERLY	BROOKS	BEVERLY.BROOKS@sakilacustomer.org	77	t	2006-02-14	2006-02-15 04:57:20	1
74	1	DENISE	KELLY	DENISE.KELLY@sakilacustomer.org	78	t	2006-02-14	2006-02-15 04:57:20	1
75	2	TAMMY	SANDERS	TAMMY.SANDERS@sakilacustomer.org	79	t	2006-02-14	2006-02-15 04:57:20	1
76	2	IRENE	PRICE	IRENE.PRICE@sakilacustomer.org	80	t	2006-02-14	2006-02-15 04:57:20	1
77	2	JANE	BENNETT	JANE.BENNETT@sakilacustomer.org	81	t	2006-02-14	2006-02-15 04:57:20	1
78	1	LORI	WOOD	LORI.WOOD@sakilacustomer.org	82	t	2006-02-14	2006-02-15 04:57:20	1
79	1	RACHEL	BARNES	RACHEL.BARNES@sakilacustomer.org	83	t	2006-02-14	2006-02-15 04:57:20	1
80	1	MARILYN	ROSS	MARILYN.ROSS@sakilacustomer.org	84	t	2006-02-14	2006-02-15 04:57:20	1
81	1	ANDREA	HENDERSON	ANDREA.HENDERSON@sakilacustomer.org	85	t	2006-02-14	2006-02-15 04:57:20	1
82	1	KATHRYN	COLEMAN	KATHRYN.COLEMAN@sakilacustomer.org	86	t	2006-02-14	2006-02-15 04:57:20	1
83	1	LOUISE	JENKINS	LOUISE.JENKINS@sakilacustomer.org	87	t	2006-02-14	2006-02-15 04:57:20	1
84	2	SARA	PERRY	SARA.PERRY@sakilacustomer.org	88	t	2006-02-14	2006-02-15 04:57:20	1
85	2	ANNE	POWELL	ANNE.POWELL@sakilacustomer.org	89	t	2006-02-14	2006-02-15 04:57:20	1
86	2	JACQUELINE	LONG	JACQUELINE.LONG@sakilacustomer.org	90	t	2006-02-14	2006-02-15 04:57:20	1
87	1	WANDA	PATTERSON	WANDA.PATTERSON@sakilacustomer.org	91	t	2006-02-14	2006-02-15 04:57:20	1
88	2	BONNIE	HUGHES	BONNIE.HUGHES@sakilacustomer.org	92	t	2006-02-14	2006-02-15 04:57:20	1
89	1	JULIA	FLORES	JULIA.FLORES@sakilacustomer.org	93	t	2006-02-14	2006-02-15 04:57:20	1
90	2	RUBY	WASHINGTON	RUBY.WASHINGTON@sakilacustomer.org	94	t	2006-02-14	2006-02-15 04:57:20	1
91	2	LOIS	BUTLER	LOIS.BUTLER@sakilacustomer.org	95	t	2006-02-14	2006-02-15 04:57:20	1
92	2	TINA	SIMMONS	TINA.SIMMONS@sakilacustomer.org	96	t	2006-02-14	2006-02-15 04:57:20	1
93	1	PHYLLIS	FOSTER	PHYLLIS.FOSTER@sakilacustomer.org	97	t	2006-02-14	2006-02-15 04:57:20	1
94	1	NORMA	GONZALES	NORMA.GONZALES@sakilacustomer.org	98	t	2006-02-14	2006-02-15 04:57:20	1
95	2	PAULA	BRYANT	PAULA.BRYANT@sakilacustomer.org	99	t	2006-02-14	2006-02-15 04:57:20	1
96	1	DIANA	ALEXANDER	DIANA.ALEXANDER@sakilacustomer.org	100	t	2006-02-14	2006-02-15 04:57:20	1
97	2	ANNIE	RUSSELL	ANNIE.RUSSELL@sakilacustomer.org	101	t	2006-02-14	2006-02-15 04:57:20	1
98	1	LILLIAN	GRIFFIN	LILLIAN.GRIFFIN@sakilacustomer.org	102	t	2006-02-14	2006-02-15 04:57:20	1
99	2	EMILY	DIAZ	EMILY.DIAZ@sakilacustomer.org	103	t	2006-02-14	2006-02-15 04:57:20	1
100	1	ROBIN	HAYES	ROBIN.HAYES@sakilacustomer.org	104	t	2006-02-14	2006-02-15 04:57:20	1
101	1	PEGGY	MYERS	PEGGY.MYERS@sakilacustomer.org	105	t	2006-02-14	2006-02-15 04:57:20	1
102	1	CRYSTAL	FORD	CRYSTAL.FORD@sakilacustomer.org	106	t	2006-02-14	2006-02-15 04:57:20	1
103	1	GLADYS	HAMILTON	GLADYS.HAMILTON@sakilacustomer.org	107	t	2006-02-14	2006-02-15 04:57:20	1
104	1	RITA	GRAHAM	RITA.GRAHAM@sakilacustomer.org	108	t	2006-02-14	2006-02-15 04:57:20	1
105	1	DAWN	SULLIVAN	DAWN.SULLIVAN@sakilacustomer.org	109	t	2006-02-14	2006-02-15 04:57:20	1
106	1	CONNIE	WALLACE	CONNIE.WALLACE@sakilacustomer.org	110	t	2006-02-14	2006-02-15 04:57:20	1
107	1	FLORENCE	WOODS	FLORENCE.WOODS@sakilacustomer.org	111	t	2006-02-14	2006-02-15 04:57:20	1
108	1	TRACY	COLE	TRACY.COLE@sakilacustomer.org	112	t	2006-02-14	2006-02-15 04:57:20	1
109	2	EDNA	WEST	EDNA.WEST@sakilacustomer.org	113	t	2006-02-14	2006-02-15 04:57:20	1
110	2	TIFFANY	JORDAN	TIFFANY.JORDAN@sakilacustomer.org	114	t	2006-02-14	2006-02-15 04:57:20	1
111	1	CARMEN	OWENS	CARMEN.OWENS@sakilacustomer.org	115	t	2006-02-14	2006-02-15 04:57:20	1
112	2	ROSA	REYNOLDS	ROSA.REYNOLDS@sakilacustomer.org	116	t	2006-02-14	2006-02-15 04:57:20	1
113	2	CINDY	FISHER	CINDY.FISHER@sakilacustomer.org	117	t	2006-02-14	2006-02-15 04:57:20	1
114	2	GRACE	ELLIS	GRACE.ELLIS@sakilacustomer.org	118	t	2006-02-14	2006-02-15 04:57:20	1
115	1	WENDY	HARRISON	WENDY.HARRISON@sakilacustomer.org	119	t	2006-02-14	2006-02-15 04:57:20	1
116	1	VICTORIA	GIBSON	VICTORIA.GIBSON@sakilacustomer.org	120	t	2006-02-14	2006-02-15 04:57:20	1
117	1	EDITH	MCDONALD	EDITH.MCDONALD@sakilacustomer.org	121	t	2006-02-14	2006-02-15 04:57:20	1
118	1	KIM	CRUZ	KIM.CRUZ@sakilacustomer.org	122	t	2006-02-14	2006-02-15 04:57:20	1
119	1	SHERRY	MARSHALL	SHERRY.MARSHALL@sakilacustomer.org	123	t	2006-02-14	2006-02-15 04:57:20	1
120	2	SYLVIA	ORTIZ	SYLVIA.ORTIZ@sakilacustomer.org	124	t	2006-02-14	2006-02-15 04:57:20	1
121	1	JOSEPHINE	GOMEZ	JOSEPHINE.GOMEZ@sakilacustomer.org	125	t	2006-02-14	2006-02-15 04:57:20	1
122	1	THELMA	MURRAY	THELMA.MURRAY@sakilacustomer.org	126	t	2006-02-14	2006-02-15 04:57:20	1
123	2	SHANNON	FREEMAN	SHANNON.FREEMAN@sakilacustomer.org	127	t	2006-02-14	2006-02-15 04:57:20	1
124	1	SHEILA	WELLS	SHEILA.WELLS@sakilacustomer.org	128	t	2006-02-14	2006-02-15 04:57:20	0
125	1	ETHEL	WEBB	ETHEL.WEBB@sakilacustomer.org	129	t	2006-02-14	2006-02-15 04:57:20	1
126	1	ELLEN	SIMPSON	ELLEN.SIMPSON@sakilacustomer.org	130	t	2006-02-14	2006-02-15 04:57:20	1
127	2	ELAINE	STEVENS	ELAINE.STEVENS@sakilacustomer.org	131	t	2006-02-14	2006-02-15 04:57:20	1
128	1	MARJORIE	TUCKER	MARJORIE.TUCKER@sakilacustomer.org	132	t	2006-02-14	2006-02-15 04:57:20	1
129	1	CARRIE	PORTER	CARRIE.PORTER@sakilacustomer.org	133	t	2006-02-14	2006-02-15 04:57:20	1
130	1	CHARLOTTE	HUNTER	CHARLOTTE.HUNTER@sakilacustomer.org	134	t	2006-02-14	2006-02-15 04:57:20	1
131	2	MONICA	HICKS	MONICA.HICKS@sakilacustomer.org	135	t	2006-02-14	2006-02-15 04:57:20	1
132	2	ESTHER	CRAWFORD	ESTHER.CRAWFORD@sakilacustomer.org	136	t	2006-02-14	2006-02-15 04:57:20	1
133	1	PAULINE	HENRY	PAULINE.HENRY@sakilacustomer.org	137	t	2006-02-14	2006-02-15 04:57:20	1
134	1	EMMA	BOYD	EMMA.BOYD@sakilacustomer.org	138	t	2006-02-14	2006-02-15 04:57:20	1
135	2	JUANITA	MASON	JUANITA.MASON@sakilacustomer.org	139	t	2006-02-14	2006-02-15 04:57:20	1
136	2	ANITA	MORALES	ANITA.MORALES@sakilacustomer.org	140	t	2006-02-14	2006-02-15 04:57:20	1
137	2	RHONDA	KENNEDY	RHONDA.KENNEDY@sakilacustomer.org	141	t	2006-02-14	2006-02-15 04:57:20	1
138	1	HAZEL	WARREN	HAZEL.WARREN@sakilacustomer.org	142	t	2006-02-14	2006-02-15 04:57:20	1
139	1	AMBER	DIXON	AMBER.DIXON@sakilacustomer.org	143	t	2006-02-14	2006-02-15 04:57:20	1
140	1	EVA	RAMOS	EVA.RAMOS@sakilacustomer.org	144	t	2006-02-14	2006-02-15 04:57:20	1
141	1	DEBBIE	REYES	DEBBIE.REYES@sakilacustomer.org	145	t	2006-02-14	2006-02-15 04:57:20	1
142	1	APRIL	BURNS	APRIL.BURNS@sakilacustomer.org	146	t	2006-02-14	2006-02-15 04:57:20	1
143	1	LESLIE	GORDON	LESLIE.GORDON@sakilacustomer.org	147	t	2006-02-14	2006-02-15 04:57:20	1
144	1	CLARA	SHAW	CLARA.SHAW@sakilacustomer.org	148	t	2006-02-14	2006-02-15 04:57:20	1
145	1	LUCILLE	HOLMES	LUCILLE.HOLMES@sakilacustomer.org	149	t	2006-02-14	2006-02-15 04:57:20	1
146	1	JAMIE	RICE	JAMIE.RICE@sakilacustomer.org	150	t	2006-02-14	2006-02-15 04:57:20	1
147	2	JOANNE	ROBERTSON	JOANNE.ROBERTSON@sakilacustomer.org	151	t	2006-02-14	2006-02-15 04:57:20	1
148	1	ELEANOR	HUNT	ELEANOR.HUNT@sakilacustomer.org	152	t	2006-02-14	2006-02-15 04:57:20	1
149	1	VALERIE	BLACK	VALERIE.BLACK@sakilacustomer.org	153	t	2006-02-14	2006-02-15 04:57:20	1
150	2	DANIELLE	DANIELS	DANIELLE.DANIELS@sakilacustomer.org	154	t	2006-02-14	2006-02-15 04:57:20	1
151	2	MEGAN	PALMER	MEGAN.PALMER@sakilacustomer.org	155	t	2006-02-14	2006-02-15 04:57:20	1
152	1	ALICIA	MILLS	ALICIA.MILLS@sakilacustomer.org	156	t	2006-02-14	2006-02-15 04:57:20	1
153	2	SUZANNE	NICHOLS	SUZANNE.NICHOLS@sakilacustomer.org	157	t	2006-02-14	2006-02-15 04:57:20	1
154	2	MICHELE	GRANT	MICHELE.GRANT@sakilacustomer.org	158	t	2006-02-14	2006-02-15 04:57:20	1
155	1	GAIL	KNIGHT	GAIL.KNIGHT@sakilacustomer.org	159	t	2006-02-14	2006-02-15 04:57:20	1
156	1	BERTHA	FERGUSON	BERTHA.FERGUSON@sakilacustomer.org	160	t	2006-02-14	2006-02-15 04:57:20	1
157	2	DARLENE	ROSE	DARLENE.ROSE@sakilacustomer.org	161	t	2006-02-14	2006-02-15 04:57:20	1
158	1	VERONICA	STONE	VERONICA.STONE@sakilacustomer.org	162	t	2006-02-14	2006-02-15 04:57:20	1
159	1	JILL	HAWKINS	JILL.HAWKINS@sakilacustomer.org	163	t	2006-02-14	2006-02-15 04:57:20	1
160	2	ERIN	DUNN	ERIN.DUNN@sakilacustomer.org	164	t	2006-02-14	2006-02-15 04:57:20	1
161	1	GERALDINE	PERKINS	GERALDINE.PERKINS@sakilacustomer.org	165	t	2006-02-14	2006-02-15 04:57:20	1
162	2	LAUREN	HUDSON	LAUREN.HUDSON@sakilacustomer.org	166	t	2006-02-14	2006-02-15 04:57:20	1
163	1	CATHY	SPENCER	CATHY.SPENCER@sakilacustomer.org	167	t	2006-02-14	2006-02-15 04:57:20	1
164	2	JOANN	GARDNER	JOANN.GARDNER@sakilacustomer.org	168	t	2006-02-14	2006-02-15 04:57:20	1
165	2	LORRAINE	STEPHENS	LORRAINE.STEPHENS@sakilacustomer.org	169	t	2006-02-14	2006-02-15 04:57:20	1
166	1	LYNN	PAYNE	LYNN.PAYNE@sakilacustomer.org	170	t	2006-02-14	2006-02-15 04:57:20	1
167	2	SALLY	PIERCE	SALLY.PIERCE@sakilacustomer.org	171	t	2006-02-14	2006-02-15 04:57:20	1
168	1	REGINA	BERRY	REGINA.BERRY@sakilacustomer.org	172	t	2006-02-14	2006-02-15 04:57:20	1
169	2	ERICA	MATTHEWS	ERICA.MATTHEWS@sakilacustomer.org	173	t	2006-02-14	2006-02-15 04:57:20	0
170	1	BEATRICE	ARNOLD	BEATRICE.ARNOLD@sakilacustomer.org	174	t	2006-02-14	2006-02-15 04:57:20	1
171	2	DOLORES	WAGNER	DOLORES.WAGNER@sakilacustomer.org	175	t	2006-02-14	2006-02-15 04:57:20	1
172	1	BERNICE	WILLIS	BERNICE.WILLIS@sakilacustomer.org	176	t	2006-02-14	2006-02-15 04:57:20	1
173	1	AUDREY	RAY	AUDREY.RAY@sakilacustomer.org	177	t	2006-02-14	2006-02-15 04:57:20	1
174	2	YVONNE	WATKINS	YVONNE.WATKINS@sakilacustomer.org	178	t	2006-02-14	2006-02-15 04:57:20	1
175	1	ANNETTE	OLSON	ANNETTE.OLSON@sakilacustomer.org	179	t	2006-02-14	2006-02-15 04:57:20	1
176	1	JUNE	CARROLL	JUNE.CARROLL@sakilacustomer.org	180	t	2006-02-14	2006-02-15 04:57:20	1
177	2	SAMANTHA	DUNCAN	SAMANTHA.DUNCAN@sakilacustomer.org	181	t	2006-02-14	2006-02-15 04:57:20	1
178	2	MARION	SNYDER	MARION.SNYDER@sakilacustomer.org	182	t	2006-02-14	2006-02-15 04:57:20	1
179	1	DANA	HART	DANA.HART@sakilacustomer.org	183	t	2006-02-14	2006-02-15 04:57:20	1
180	2	STACY	CUNNINGHAM	STACY.CUNNINGHAM@sakilacustomer.org	184	t	2006-02-14	2006-02-15 04:57:20	1
181	2	ANA	BRADLEY	ANA.BRADLEY@sakilacustomer.org	185	t	2006-02-14	2006-02-15 04:57:20	1
182	1	RENEE	LANE	RENEE.LANE@sakilacustomer.org	186	t	2006-02-14	2006-02-15 04:57:20	1
183	2	IDA	ANDREWS	IDA.ANDREWS@sakilacustomer.org	187	t	2006-02-14	2006-02-15 04:57:20	1
184	1	VIVIAN	RUIZ	VIVIAN.RUIZ@sakilacustomer.org	188	t	2006-02-14	2006-02-15 04:57:20	1
185	1	ROBERTA	HARPER	ROBERTA.HARPER@sakilacustomer.org	189	t	2006-02-14	2006-02-15 04:57:20	1
186	2	HOLLY	FOX	HOLLY.FOX@sakilacustomer.org	190	t	2006-02-14	2006-02-15 04:57:20	1
187	2	BRITTANY	RILEY	BRITTANY.RILEY@sakilacustomer.org	191	t	2006-02-14	2006-02-15 04:57:20	1
188	1	MELANIE	ARMSTRONG	MELANIE.ARMSTRONG@sakilacustomer.org	192	t	2006-02-14	2006-02-15 04:57:20	1
189	1	LORETTA	CARPENTER	LORETTA.CARPENTER@sakilacustomer.org	193	t	2006-02-14	2006-02-15 04:57:20	1
190	2	YOLANDA	WEAVER	YOLANDA.WEAVER@sakilacustomer.org	194	t	2006-02-14	2006-02-15 04:57:20	1
191	1	JEANETTE	GREENE	JEANETTE.GREENE@sakilacustomer.org	195	t	2006-02-14	2006-02-15 04:57:20	1
192	1	LAURIE	LAWRENCE	LAURIE.LAWRENCE@sakilacustomer.org	196	t	2006-02-14	2006-02-15 04:57:20	1
193	2	KATIE	ELLIOTT	KATIE.ELLIOTT@sakilacustomer.org	197	t	2006-02-14	2006-02-15 04:57:20	1
194	2	KRISTEN	CHAVEZ	KRISTEN.CHAVEZ@sakilacustomer.org	198	t	2006-02-14	2006-02-15 04:57:20	1
195	1	VANESSA	SIMS	VANESSA.SIMS@sakilacustomer.org	199	t	2006-02-14	2006-02-15 04:57:20	1
196	1	ALMA	AUSTIN	ALMA.AUSTIN@sakilacustomer.org	200	t	2006-02-14	2006-02-15 04:57:20	1
197	2	SUE	PETERS	SUE.PETERS@sakilacustomer.org	201	t	2006-02-14	2006-02-15 04:57:20	1
198	2	ELSIE	KELLEY	ELSIE.KELLEY@sakilacustomer.org	202	t	2006-02-14	2006-02-15 04:57:20	1
199	2	BETH	FRANKLIN	BETH.FRANKLIN@sakilacustomer.org	203	t	2006-02-14	2006-02-15 04:57:20	1
200	2	JEANNE	LAWSON	JEANNE.LAWSON@sakilacustomer.org	204	t	2006-02-14	2006-02-15 04:57:20	1
201	1	VICKI	FIELDS	VICKI.FIELDS@sakilacustomer.org	205	t	2006-02-14	2006-02-15 04:57:20	1
202	2	CARLA	GUTIERREZ	CARLA.GUTIERREZ@sakilacustomer.org	206	t	2006-02-14	2006-02-15 04:57:20	1
203	1	TARA	RYAN	TARA.RYAN@sakilacustomer.org	207	t	2006-02-14	2006-02-15 04:57:20	1
204	1	ROSEMARY	SCHMIDT	ROSEMARY.SCHMIDT@sakilacustomer.org	208	t	2006-02-14	2006-02-15 04:57:20	1
205	2	EILEEN	CARR	EILEEN.CARR@sakilacustomer.org	209	t	2006-02-14	2006-02-15 04:57:20	1
206	1	TERRI	VASQUEZ	TERRI.VASQUEZ@sakilacustomer.org	210	t	2006-02-14	2006-02-15 04:57:20	1
207	1	GERTRUDE	CASTILLO	GERTRUDE.CASTILLO@sakilacustomer.org	211	t	2006-02-14	2006-02-15 04:57:20	1
208	1	LUCY	WHEELER	LUCY.WHEELER@sakilacustomer.org	212	t	2006-02-14	2006-02-15 04:57:20	1
209	2	TONYA	CHAPMAN	TONYA.CHAPMAN@sakilacustomer.org	213	t	2006-02-14	2006-02-15 04:57:20	1
210	2	ELLA	OLIVER	ELLA.OLIVER@sakilacustomer.org	214	t	2006-02-14	2006-02-15 04:57:20	1
211	1	STACEY	MONTGOMERY	STACEY.MONTGOMERY@sakilacustomer.org	215	t	2006-02-14	2006-02-15 04:57:20	1
212	2	WILMA	RICHARDS	WILMA.RICHARDS@sakilacustomer.org	216	t	2006-02-14	2006-02-15 04:57:20	1
213	1	GINA	WILLIAMSON	GINA.WILLIAMSON@sakilacustomer.org	217	t	2006-02-14	2006-02-15 04:57:20	1
214	1	KRISTIN	JOHNSTON	KRISTIN.JOHNSTON@sakilacustomer.org	218	t	2006-02-14	2006-02-15 04:57:20	1
215	2	JESSIE	BANKS	JESSIE.BANKS@sakilacustomer.org	219	t	2006-02-14	2006-02-15 04:57:20	1
216	1	NATALIE	MEYER	NATALIE.MEYER@sakilacustomer.org	220	t	2006-02-14	2006-02-15 04:57:20	1
217	2	AGNES	BISHOP	AGNES.BISHOP@sakilacustomer.org	221	t	2006-02-14	2006-02-15 04:57:20	1
218	1	VERA	MCCOY	VERA.MCCOY@sakilacustomer.org	222	t	2006-02-14	2006-02-15 04:57:20	1
219	2	WILLIE	HOWELL	WILLIE.HOWELL@sakilacustomer.org	223	t	2006-02-14	2006-02-15 04:57:20	1
220	2	CHARLENE	ALVAREZ	CHARLENE.ALVAREZ@sakilacustomer.org	224	t	2006-02-14	2006-02-15 04:57:20	1
221	1	BESSIE	MORRISON	BESSIE.MORRISON@sakilacustomer.org	225	t	2006-02-14	2006-02-15 04:57:20	1
222	2	DELORES	HANSEN	DELORES.HANSEN@sakilacustomer.org	226	t	2006-02-14	2006-02-15 04:57:20	1
223	1	MELINDA	FERNANDEZ	MELINDA.FERNANDEZ@sakilacustomer.org	227	t	2006-02-14	2006-02-15 04:57:20	1
224	2	PEARL	GARZA	PEARL.GARZA@sakilacustomer.org	228	t	2006-02-14	2006-02-15 04:57:20	1
225	1	ARLENE	HARVEY	ARLENE.HARVEY@sakilacustomer.org	229	t	2006-02-14	2006-02-15 04:57:20	1
226	2	MAUREEN	LITTLE	MAUREEN.LITTLE@sakilacustomer.org	230	t	2006-02-14	2006-02-15 04:57:20	1
227	1	COLLEEN	BURTON	COLLEEN.BURTON@sakilacustomer.org	231	t	2006-02-14	2006-02-15 04:57:20	1
228	2	ALLISON	STANLEY	ALLISON.STANLEY@sakilacustomer.org	232	t	2006-02-14	2006-02-15 04:57:20	1
229	1	TAMARA	NGUYEN	TAMARA.NGUYEN@sakilacustomer.org	233	t	2006-02-14	2006-02-15 04:57:20	1
230	2	JOY	GEORGE	JOY.GEORGE@sakilacustomer.org	234	t	2006-02-14	2006-02-15 04:57:20	1
231	1	GEORGIA	JACOBS	GEORGIA.JACOBS@sakilacustomer.org	235	t	2006-02-14	2006-02-15 04:57:20	1
232	2	CONSTANCE	REID	CONSTANCE.REID@sakilacustomer.org	236	t	2006-02-14	2006-02-15 04:57:20	1
233	2	LILLIE	KIM	LILLIE.KIM@sakilacustomer.org	237	t	2006-02-14	2006-02-15 04:57:20	1
234	1	CLAUDIA	FULLER	CLAUDIA.FULLER@sakilacustomer.org	238	t	2006-02-14	2006-02-15 04:57:20	1
235	1	JACKIE	LYNCH	JACKIE.LYNCH@sakilacustomer.org	239	t	2006-02-14	2006-02-15 04:57:20	1
236	1	MARCIA	DEAN	MARCIA.DEAN@sakilacustomer.org	240	t	2006-02-14	2006-02-15 04:57:20	1
237	1	TANYA	GILBERT	TANYA.GILBERT@sakilacustomer.org	241	t	2006-02-14	2006-02-15 04:57:20	1
238	1	NELLIE	GARRETT	NELLIE.GARRETT@sakilacustomer.org	242	t	2006-02-14	2006-02-15 04:57:20	1
239	2	MINNIE	ROMERO	MINNIE.ROMERO@sakilacustomer.org	243	t	2006-02-14	2006-02-15 04:57:20	1
240	1	MARLENE	WELCH	MARLENE.WELCH@sakilacustomer.org	244	t	2006-02-14	2006-02-15 04:57:20	1
241	2	HEIDI	LARSON	HEIDI.LARSON@sakilacustomer.org	245	t	2006-02-14	2006-02-15 04:57:20	0
242	1	GLENDA	FRAZIER	GLENDA.FRAZIER@sakilacustomer.org	246	t	2006-02-14	2006-02-15 04:57:20	1
243	1	LYDIA	BURKE	LYDIA.BURKE@sakilacustomer.org	247	t	2006-02-14	2006-02-15 04:57:20	1
244	2	VIOLA	HANSON	VIOLA.HANSON@sakilacustomer.org	248	t	2006-02-14	2006-02-15 04:57:20	1
245	1	COURTNEY	DAY	COURTNEY.DAY@sakilacustomer.org	249	t	2006-02-14	2006-02-15 04:57:20	1
246	1	MARIAN	MENDOZA	MARIAN.MENDOZA@sakilacustomer.org	250	t	2006-02-14	2006-02-15 04:57:20	1
247	1	STELLA	MORENO	STELLA.MORENO@sakilacustomer.org	251	t	2006-02-14	2006-02-15 04:57:20	1
248	1	CAROLINE	BOWMAN	CAROLINE.BOWMAN@sakilacustomer.org	252	t	2006-02-14	2006-02-15 04:57:20	1
249	2	DORA	MEDINA	DORA.MEDINA@sakilacustomer.org	253	t	2006-02-14	2006-02-15 04:57:20	1
250	2	JO	FOWLER	JO.FOWLER@sakilacustomer.org	254	t	2006-02-14	2006-02-15 04:57:20	1
251	2	VICKIE	BREWER	VICKIE.BREWER@sakilacustomer.org	255	t	2006-02-14	2006-02-15 04:57:20	1
252	2	MATTIE	HOFFMAN	MATTIE.HOFFMAN@sakilacustomer.org	256	t	2006-02-14	2006-02-15 04:57:20	1
253	1	TERRY	CARLSON	TERRY.CARLSON@sakilacustomer.org	258	t	2006-02-14	2006-02-15 04:57:20	1
254	2	MAXINE	SILVA	MAXINE.SILVA@sakilacustomer.org	259	t	2006-02-14	2006-02-15 04:57:20	1
255	2	IRMA	PEARSON	IRMA.PEARSON@sakilacustomer.org	260	t	2006-02-14	2006-02-15 04:57:20	1
256	2	MABEL	HOLLAND	MABEL.HOLLAND@sakilacustomer.org	261	t	2006-02-14	2006-02-15 04:57:20	1
257	2	MARSHA	DOUGLAS	MARSHA.DOUGLAS@sakilacustomer.org	262	t	2006-02-14	2006-02-15 04:57:20	1
258	1	MYRTLE	FLEMING	MYRTLE.FLEMING@sakilacustomer.org	263	t	2006-02-14	2006-02-15 04:57:20	1
259	2	LENA	JENSEN	LENA.JENSEN@sakilacustomer.org	264	t	2006-02-14	2006-02-15 04:57:20	1
260	1	CHRISTY	VARGAS	CHRISTY.VARGAS@sakilacustomer.org	265	t	2006-02-14	2006-02-15 04:57:20	1
261	1	DEANNA	BYRD	DEANNA.BYRD@sakilacustomer.org	266	t	2006-02-14	2006-02-15 04:57:20	1
262	2	PATSY	DAVIDSON	PATSY.DAVIDSON@sakilacustomer.org	267	t	2006-02-14	2006-02-15 04:57:20	1
263	1	HILDA	HOPKINS	HILDA.HOPKINS@sakilacustomer.org	268	t	2006-02-14	2006-02-15 04:57:20	1
264	1	GWENDOLYN	MAY	GWENDOLYN.MAY@sakilacustomer.org	269	t	2006-02-14	2006-02-15 04:57:20	1
265	2	JENNIE	TERRY	JENNIE.TERRY@sakilacustomer.org	270	t	2006-02-14	2006-02-15 04:57:20	1
266	2	NORA	HERRERA	NORA.HERRERA@sakilacustomer.org	271	t	2006-02-14	2006-02-15 04:57:20	1
267	1	MARGIE	WADE	MARGIE.WADE@sakilacustomer.org	272	t	2006-02-14	2006-02-15 04:57:20	1
268	1	NINA	SOTO	NINA.SOTO@sakilacustomer.org	273	t	2006-02-14	2006-02-15 04:57:20	1
269	1	CASSANDRA	WALTERS	CASSANDRA.WALTERS@sakilacustomer.org	274	t	2006-02-14	2006-02-15 04:57:20	1
270	1	LEAH	CURTIS	LEAH.CURTIS@sakilacustomer.org	275	t	2006-02-14	2006-02-15 04:57:20	1
271	1	PENNY	NEAL	PENNY.NEAL@sakilacustomer.org	276	t	2006-02-14	2006-02-15 04:57:20	0
272	1	KAY	CALDWELL	KAY.CALDWELL@sakilacustomer.org	277	t	2006-02-14	2006-02-15 04:57:20	1
273	2	PRISCILLA	LOWE	PRISCILLA.LOWE@sakilacustomer.org	278	t	2006-02-14	2006-02-15 04:57:20	1
274	1	NAOMI	JENNINGS	NAOMI.JENNINGS@sakilacustomer.org	279	t	2006-02-14	2006-02-15 04:57:20	1
275	2	CAROLE	BARNETT	CAROLE.BARNETT@sakilacustomer.org	280	t	2006-02-14	2006-02-15 04:57:20	1
276	1	BRANDY	GRAVES	BRANDY.GRAVES@sakilacustomer.org	281	t	2006-02-14	2006-02-15 04:57:20	1
277	2	OLGA	JIMENEZ	OLGA.JIMENEZ@sakilacustomer.org	282	t	2006-02-14	2006-02-15 04:57:20	1
278	2	BILLIE	HORTON	BILLIE.HORTON@sakilacustomer.org	283	t	2006-02-14	2006-02-15 04:57:20	1
279	2	DIANNE	SHELTON	DIANNE.SHELTON@sakilacustomer.org	284	t	2006-02-14	2006-02-15 04:57:20	1
280	2	TRACEY	BARRETT	TRACEY.BARRETT@sakilacustomer.org	285	t	2006-02-14	2006-02-15 04:57:20	1
281	2	LEONA	OBRIEN	LEONA.OBRIEN@sakilacustomer.org	286	t	2006-02-14	2006-02-15 04:57:20	1
282	2	JENNY	CASTRO	JENNY.CASTRO@sakilacustomer.org	287	t	2006-02-14	2006-02-15 04:57:20	1
283	1	FELICIA	SUTTON	FELICIA.SUTTON@sakilacustomer.org	288	t	2006-02-14	2006-02-15 04:57:20	1
284	1	SONIA	GREGORY	SONIA.GREGORY@sakilacustomer.org	289	t	2006-02-14	2006-02-15 04:57:20	1
285	1	MIRIAM	MCKINNEY	MIRIAM.MCKINNEY@sakilacustomer.org	290	t	2006-02-14	2006-02-15 04:57:20	1
286	1	VELMA	LUCAS	VELMA.LUCAS@sakilacustomer.org	291	t	2006-02-14	2006-02-15 04:57:20	1
287	2	BECKY	MILES	BECKY.MILES@sakilacustomer.org	292	t	2006-02-14	2006-02-15 04:57:20	1
288	1	BOBBIE	CRAIG	BOBBIE.CRAIG@sakilacustomer.org	293	t	2006-02-14	2006-02-15 04:57:20	1
289	1	VIOLET	RODRIQUEZ	VIOLET.RODRIQUEZ@sakilacustomer.org	294	t	2006-02-14	2006-02-15 04:57:20	1
290	1	KRISTINA	CHAMBERS	KRISTINA.CHAMBERS@sakilacustomer.org	295	t	2006-02-14	2006-02-15 04:57:20	1
291	1	TONI	HOLT	TONI.HOLT@sakilacustomer.org	296	t	2006-02-14	2006-02-15 04:57:20	1
292	2	MISTY	LAMBERT	MISTY.LAMBERT@sakilacustomer.org	297	t	2006-02-14	2006-02-15 04:57:20	1
293	2	MAE	FLETCHER	MAE.FLETCHER@sakilacustomer.org	298	t	2006-02-14	2006-02-15 04:57:20	1
294	2	SHELLY	WATTS	SHELLY.WATTS@sakilacustomer.org	299	t	2006-02-14	2006-02-15 04:57:20	1
295	1	DAISY	BATES	DAISY.BATES@sakilacustomer.org	300	t	2006-02-14	2006-02-15 04:57:20	1
296	2	RAMONA	HALE	RAMONA.HALE@sakilacustomer.org	301	t	2006-02-14	2006-02-15 04:57:20	1
297	1	SHERRI	RHODES	SHERRI.RHODES@sakilacustomer.org	302	t	2006-02-14	2006-02-15 04:57:20	1
298	1	ERIKA	PENA	ERIKA.PENA@sakilacustomer.org	303	t	2006-02-14	2006-02-15 04:57:20	1
299	2	JAMES	GANNON	JAMES.GANNON@sakilacustomer.org	304	t	2006-02-14	2006-02-15 04:57:20	1
300	1	JOHN	FARNSWORTH	JOHN.FARNSWORTH@sakilacustomer.org	305	t	2006-02-14	2006-02-15 04:57:20	1
301	2	ROBERT	BAUGHMAN	ROBERT.BAUGHMAN@sakilacustomer.org	306	t	2006-02-14	2006-02-15 04:57:20	1
302	1	MICHAEL	SILVERMAN	MICHAEL.SILVERMAN@sakilacustomer.org	307	t	2006-02-14	2006-02-15 04:57:20	1
303	2	WILLIAM	SATTERFIELD	WILLIAM.SATTERFIELD@sakilacustomer.org	308	t	2006-02-14	2006-02-15 04:57:20	1
304	2	DAVID	ROYAL	DAVID.ROYAL@sakilacustomer.org	309	t	2006-02-14	2006-02-15 04:57:20	1
305	1	RICHARD	MCCRARY	RICHARD.MCCRARY@sakilacustomer.org	310	t	2006-02-14	2006-02-15 04:57:20	1
306	1	CHARLES	KOWALSKI	CHARLES.KOWALSKI@sakilacustomer.org	311	t	2006-02-14	2006-02-15 04:57:20	1
307	2	JOSEPH	JOY	JOSEPH.JOY@sakilacustomer.org	312	t	2006-02-14	2006-02-15 04:57:20	1
308	1	THOMAS	GRIGSBY	THOMAS.GRIGSBY@sakilacustomer.org	313	t	2006-02-14	2006-02-15 04:57:20	1
309	1	CHRISTOPHER	GRECO	CHRISTOPHER.GRECO@sakilacustomer.org	314	t	2006-02-14	2006-02-15 04:57:20	1
310	2	DANIEL	CABRAL	DANIEL.CABRAL@sakilacustomer.org	315	t	2006-02-14	2006-02-15 04:57:20	1
311	2	PAUL	TROUT	PAUL.TROUT@sakilacustomer.org	316	t	2006-02-14	2006-02-15 04:57:20	1
312	2	MARK	RINEHART	MARK.RINEHART@sakilacustomer.org	317	t	2006-02-14	2006-02-15 04:57:20	1
313	2	DONALD	MAHON	DONALD.MAHON@sakilacustomer.org	318	t	2006-02-14	2006-02-15 04:57:20	1
314	1	GEORGE	LINTON	GEORGE.LINTON@sakilacustomer.org	319	t	2006-02-14	2006-02-15 04:57:20	1
315	2	KENNETH	GOODEN	KENNETH.GOODEN@sakilacustomer.org	320	t	2006-02-14	2006-02-15 04:57:20	0
316	1	STEVEN	CURLEY	STEVEN.CURLEY@sakilacustomer.org	321	t	2006-02-14	2006-02-15 04:57:20	1
317	2	EDWARD	BAUGH	EDWARD.BAUGH@sakilacustomer.org	322	t	2006-02-14	2006-02-15 04:57:20	1
318	1	BRIAN	WYMAN	BRIAN.WYMAN@sakilacustomer.org	323	t	2006-02-14	2006-02-15 04:57:20	1
319	2	RONALD	WEINER	RONALD.WEINER@sakilacustomer.org	324	t	2006-02-14	2006-02-15 04:57:20	1
320	2	ANTHONY	SCHWAB	ANTHONY.SCHWAB@sakilacustomer.org	325	t	2006-02-14	2006-02-15 04:57:20	1
321	1	KEVIN	SCHULER	KEVIN.SCHULER@sakilacustomer.org	326	t	2006-02-14	2006-02-15 04:57:20	1
322	1	JASON	MORRISSEY	JASON.MORRISSEY@sakilacustomer.org	327	t	2006-02-14	2006-02-15 04:57:20	1
323	2	MATTHEW	MAHAN	MATTHEW.MAHAN@sakilacustomer.org	328	t	2006-02-14	2006-02-15 04:57:20	1
324	2	GARY	COY	GARY.COY@sakilacustomer.org	329	t	2006-02-14	2006-02-15 04:57:20	1
325	1	TIMOTHY	BUNN	TIMOTHY.BUNN@sakilacustomer.org	330	t	2006-02-14	2006-02-15 04:57:20	1
326	1	JOSE	ANDREW	JOSE.ANDREW@sakilacustomer.org	331	t	2006-02-14	2006-02-15 04:57:20	1
327	2	LARRY	THRASHER	LARRY.THRASHER@sakilacustomer.org	332	t	2006-02-14	2006-02-15 04:57:20	1
328	2	JEFFREY	SPEAR	JEFFREY.SPEAR@sakilacustomer.org	333	t	2006-02-14	2006-02-15 04:57:20	1
329	2	FRANK	WAGGONER	FRANK.WAGGONER@sakilacustomer.org	334	t	2006-02-14	2006-02-15 04:57:20	1
330	1	SCOTT	SHELLEY	SCOTT.SHELLEY@sakilacustomer.org	335	t	2006-02-14	2006-02-15 04:57:20	1
331	1	ERIC	ROBERT	ERIC.ROBERT@sakilacustomer.org	336	t	2006-02-14	2006-02-15 04:57:20	1
332	1	STEPHEN	QUALLS	STEPHEN.QUALLS@sakilacustomer.org	337	t	2006-02-14	2006-02-15 04:57:20	1
333	2	ANDREW	PURDY	ANDREW.PURDY@sakilacustomer.org	338	t	2006-02-14	2006-02-15 04:57:20	1
334	2	RAYMOND	MCWHORTER	RAYMOND.MCWHORTER@sakilacustomer.org	339	t	2006-02-14	2006-02-15 04:57:20	1
335	1	GREGORY	MAULDIN	GREGORY.MAULDIN@sakilacustomer.org	340	t	2006-02-14	2006-02-15 04:57:20	1
336	1	JOSHUA	MARK	JOSHUA.MARK@sakilacustomer.org	341	t	2006-02-14	2006-02-15 04:57:20	1
337	1	JERRY	JORDON	JERRY.JORDON@sakilacustomer.org	342	t	2006-02-14	2006-02-15 04:57:20	1
338	1	DENNIS	GILMAN	DENNIS.GILMAN@sakilacustomer.org	343	t	2006-02-14	2006-02-15 04:57:20	1
339	2	WALTER	PERRYMAN	WALTER.PERRYMAN@sakilacustomer.org	344	t	2006-02-14	2006-02-15 04:57:20	1
340	1	PATRICK	NEWSOM	PATRICK.NEWSOM@sakilacustomer.org	345	t	2006-02-14	2006-02-15 04:57:20	1
341	1	PETER	MENARD	PETER.MENARD@sakilacustomer.org	346	t	2006-02-14	2006-02-15 04:57:20	1
342	1	HAROLD	MARTINO	HAROLD.MARTINO@sakilacustomer.org	347	t	2006-02-14	2006-02-15 04:57:20	1
343	1	DOUGLAS	GRAF	DOUGLAS.GRAF@sakilacustomer.org	348	t	2006-02-14	2006-02-15 04:57:20	1
344	1	HENRY	BILLINGSLEY	HENRY.BILLINGSLEY@sakilacustomer.org	349	t	2006-02-14	2006-02-15 04:57:20	1
345	1	CARL	ARTIS	CARL.ARTIS@sakilacustomer.org	350	t	2006-02-14	2006-02-15 04:57:20	1
346	1	ARTHUR	SIMPKINS	ARTHUR.SIMPKINS@sakilacustomer.org	351	t	2006-02-14	2006-02-15 04:57:20	1
347	2	RYAN	SALISBURY	RYAN.SALISBURY@sakilacustomer.org	352	t	2006-02-14	2006-02-15 04:57:20	1
348	2	ROGER	QUINTANILLA	ROGER.QUINTANILLA@sakilacustomer.org	353	t	2006-02-14	2006-02-15 04:57:20	1
349	2	JOE	GILLILAND	JOE.GILLILAND@sakilacustomer.org	354	t	2006-02-14	2006-02-15 04:57:20	1
350	1	JUAN	FRALEY	JUAN.FRALEY@sakilacustomer.org	355	t	2006-02-14	2006-02-15 04:57:20	1
351	1	JACK	FOUST	JACK.FOUST@sakilacustomer.org	356	t	2006-02-14	2006-02-15 04:57:20	1
352	1	ALBERT	CROUSE	ALBERT.CROUSE@sakilacustomer.org	357	t	2006-02-14	2006-02-15 04:57:20	1
353	1	JONATHAN	SCARBOROUGH	JONATHAN.SCARBOROUGH@sakilacustomer.org	358	t	2006-02-14	2006-02-15 04:57:20	1
354	2	JUSTIN	NGO	JUSTIN.NGO@sakilacustomer.org	359	t	2006-02-14	2006-02-15 04:57:20	1
355	2	TERRY	GRISSOM	TERRY.GRISSOM@sakilacustomer.org	360	t	2006-02-14	2006-02-15 04:57:20	1
356	2	GERALD	FULTZ	GERALD.FULTZ@sakilacustomer.org	361	t	2006-02-14	2006-02-15 04:57:20	1
357	1	KEITH	RICO	KEITH.RICO@sakilacustomer.org	362	t	2006-02-14	2006-02-15 04:57:20	1
358	2	SAMUEL	MARLOW	SAMUEL.MARLOW@sakilacustomer.org	363	t	2006-02-14	2006-02-15 04:57:20	1
359	2	WILLIE	MARKHAM	WILLIE.MARKHAM@sakilacustomer.org	364	t	2006-02-14	2006-02-15 04:57:20	1
360	2	RALPH	MADRIGAL	RALPH.MADRIGAL@sakilacustomer.org	365	t	2006-02-14	2006-02-15 04:57:20	1
361	2	LAWRENCE	LAWTON	LAWRENCE.LAWTON@sakilacustomer.org	366	t	2006-02-14	2006-02-15 04:57:20	1
362	1	NICHOLAS	BARFIELD	NICHOLAS.BARFIELD@sakilacustomer.org	367	t	2006-02-14	2006-02-15 04:57:20	1
363	2	ROY	WHITING	ROY.WHITING@sakilacustomer.org	368	t	2006-02-14	2006-02-15 04:57:20	1
364	1	BENJAMIN	VARNEY	BENJAMIN.VARNEY@sakilacustomer.org	369	t	2006-02-14	2006-02-15 04:57:20	1
365	2	BRUCE	SCHWARZ	BRUCE.SCHWARZ@sakilacustomer.org	370	t	2006-02-14	2006-02-15 04:57:20	1
366	1	BRANDON	HUEY	BRANDON.HUEY@sakilacustomer.org	371	t	2006-02-14	2006-02-15 04:57:20	1
367	1	ADAM	GOOCH	ADAM.GOOCH@sakilacustomer.org	372	t	2006-02-14	2006-02-15 04:57:20	1
368	1	HARRY	ARCE	HARRY.ARCE@sakilacustomer.org	373	t	2006-02-14	2006-02-15 04:57:20	0
369	2	FRED	WHEAT	FRED.WHEAT@sakilacustomer.org	374	t	2006-02-14	2006-02-15 04:57:20	1
370	2	WAYNE	TRUONG	WAYNE.TRUONG@sakilacustomer.org	375	t	2006-02-14	2006-02-15 04:57:20	1
371	1	BILLY	POULIN	BILLY.POULIN@sakilacustomer.org	376	t	2006-02-14	2006-02-15 04:57:20	1
372	2	STEVE	MACKENZIE	STEVE.MACKENZIE@sakilacustomer.org	377	t	2006-02-14	2006-02-15 04:57:20	1
373	1	LOUIS	LEONE	LOUIS.LEONE@sakilacustomer.org	378	t	2006-02-14	2006-02-15 04:57:20	1
374	2	JEREMY	HURTADO	JEREMY.HURTADO@sakilacustomer.org	379	t	2006-02-14	2006-02-15 04:57:20	1
375	2	AARON	SELBY	AARON.SELBY@sakilacustomer.org	380	t	2006-02-14	2006-02-15 04:57:20	1
376	1	RANDY	GAITHER	RANDY.GAITHER@sakilacustomer.org	381	t	2006-02-14	2006-02-15 04:57:20	1
377	1	HOWARD	FORTNER	HOWARD.FORTNER@sakilacustomer.org	382	t	2006-02-14	2006-02-15 04:57:20	1
378	1	EUGENE	CULPEPPER	EUGENE.CULPEPPER@sakilacustomer.org	383	t	2006-02-14	2006-02-15 04:57:20	1
379	1	CARLOS	COUGHLIN	CARLOS.COUGHLIN@sakilacustomer.org	384	t	2006-02-14	2006-02-15 04:57:20	1
380	1	RUSSELL	BRINSON	RUSSELL.BRINSON@sakilacustomer.org	385	t	2006-02-14	2006-02-15 04:57:20	1
381	2	BOBBY	BOUDREAU	BOBBY.BOUDREAU@sakilacustomer.org	386	t	2006-02-14	2006-02-15 04:57:20	1
382	2	VICTOR	BARKLEY	VICTOR.BARKLEY@sakilacustomer.org	387	t	2006-02-14	2006-02-15 04:57:20	1
383	1	MARTIN	BALES	MARTIN.BALES@sakilacustomer.org	388	t	2006-02-14	2006-02-15 04:57:20	1
384	2	ERNEST	STEPP	ERNEST.STEPP@sakilacustomer.org	389	t	2006-02-14	2006-02-15 04:57:20	1
385	1	PHILLIP	HOLM	PHILLIP.HOLM@sakilacustomer.org	390	t	2006-02-14	2006-02-15 04:57:20	1
386	1	TODD	TAN	TODD.TAN@sakilacustomer.org	391	t	2006-02-14	2006-02-15 04:57:20	1
387	2	JESSE	SCHILLING	JESSE.SCHILLING@sakilacustomer.org	392	t	2006-02-14	2006-02-15 04:57:20	1
388	2	CRAIG	MORRELL	CRAIG.MORRELL@sakilacustomer.org	393	t	2006-02-14	2006-02-15 04:57:20	1
389	1	ALAN	KAHN	ALAN.KAHN@sakilacustomer.org	394	t	2006-02-14	2006-02-15 04:57:20	1
390	1	SHAWN	HEATON	SHAWN.HEATON@sakilacustomer.org	395	t	2006-02-14	2006-02-15 04:57:20	1
391	1	CLARENCE	GAMEZ	CLARENCE.GAMEZ@sakilacustomer.org	396	t	2006-02-14	2006-02-15 04:57:20	1
392	2	SEAN	DOUGLASS	SEAN.DOUGLASS@sakilacustomer.org	397	t	2006-02-14	2006-02-15 04:57:20	1
393	1	PHILIP	CAUSEY	PHILIP.CAUSEY@sakilacustomer.org	398	t	2006-02-14	2006-02-15 04:57:20	1
394	2	CHRIS	BROTHERS	CHRIS.BROTHERS@sakilacustomer.org	399	t	2006-02-14	2006-02-15 04:57:20	1
395	2	JOHNNY	TURPIN	JOHNNY.TURPIN@sakilacustomer.org	400	t	2006-02-14	2006-02-15 04:57:20	1
396	1	EARL	SHANKS	EARL.SHANKS@sakilacustomer.org	401	t	2006-02-14	2006-02-15 04:57:20	1
397	1	JIMMY	SCHRADER	JIMMY.SCHRADER@sakilacustomer.org	402	t	2006-02-14	2006-02-15 04:57:20	1
398	1	ANTONIO	MEEK	ANTONIO.MEEK@sakilacustomer.org	403	t	2006-02-14	2006-02-15 04:57:20	1
399	1	DANNY	ISOM	DANNY.ISOM@sakilacustomer.org	404	t	2006-02-14	2006-02-15 04:57:20	1
400	2	BRYAN	HARDISON	BRYAN.HARDISON@sakilacustomer.org	405	t	2006-02-14	2006-02-15 04:57:20	1
401	2	TONY	CARRANZA	TONY.CARRANZA@sakilacustomer.org	406	t	2006-02-14	2006-02-15 04:57:20	1
402	1	LUIS	YANEZ	LUIS.YANEZ@sakilacustomer.org	407	t	2006-02-14	2006-02-15 04:57:20	1
403	1	MIKE	WAY	MIKE.WAY@sakilacustomer.org	408	t	2006-02-14	2006-02-15 04:57:20	1
404	2	STANLEY	SCROGGINS	STANLEY.SCROGGINS@sakilacustomer.org	409	t	2006-02-14	2006-02-15 04:57:20	1
405	1	LEONARD	SCHOFIELD	LEONARD.SCHOFIELD@sakilacustomer.org	410	t	2006-02-14	2006-02-15 04:57:20	1
406	1	NATHAN	RUNYON	NATHAN.RUNYON@sakilacustomer.org	411	t	2006-02-14	2006-02-15 04:57:20	0
407	1	DALE	RATCLIFF	DALE.RATCLIFF@sakilacustomer.org	412	t	2006-02-14	2006-02-15 04:57:20	1
408	1	MANUEL	MURRELL	MANUEL.MURRELL@sakilacustomer.org	413	t	2006-02-14	2006-02-15 04:57:20	1
409	2	RODNEY	MOELLER	RODNEY.MOELLER@sakilacustomer.org	414	t	2006-02-14	2006-02-15 04:57:20	1
410	2	CURTIS	IRBY	CURTIS.IRBY@sakilacustomer.org	415	t	2006-02-14	2006-02-15 04:57:20	1
411	1	NORMAN	CURRIER	NORMAN.CURRIER@sakilacustomer.org	416	t	2006-02-14	2006-02-15 04:57:20	1
412	2	ALLEN	BUTTERFIELD	ALLEN.BUTTERFIELD@sakilacustomer.org	417	t	2006-02-14	2006-02-15 04:57:20	1
413	2	MARVIN	YEE	MARVIN.YEE@sakilacustomer.org	418	t	2006-02-14	2006-02-15 04:57:20	1
414	1	VINCENT	RALSTON	VINCENT.RALSTON@sakilacustomer.org	419	t	2006-02-14	2006-02-15 04:57:20	1
415	1	GLENN	PULLEN	GLENN.PULLEN@sakilacustomer.org	420	t	2006-02-14	2006-02-15 04:57:20	1
416	2	JEFFERY	PINSON	JEFFERY.PINSON@sakilacustomer.org	421	t	2006-02-14	2006-02-15 04:57:20	1
417	1	TRAVIS	ESTEP	TRAVIS.ESTEP@sakilacustomer.org	422	t	2006-02-14	2006-02-15 04:57:20	1
418	2	JEFF	EAST	JEFF.EAST@sakilacustomer.org	423	t	2006-02-14	2006-02-15 04:57:20	1
419	1	CHAD	CARBONE	CHAD.CARBONE@sakilacustomer.org	424	t	2006-02-14	2006-02-15 04:57:20	1
420	1	JACOB	LANCE	JACOB.LANCE@sakilacustomer.org	425	t	2006-02-14	2006-02-15 04:57:20	1
421	1	LEE	HAWKS	LEE.HAWKS@sakilacustomer.org	426	t	2006-02-14	2006-02-15 04:57:20	1
422	1	MELVIN	ELLINGTON	MELVIN.ELLINGTON@sakilacustomer.org	427	t	2006-02-14	2006-02-15 04:57:20	1
423	2	ALFRED	CASILLAS	ALFRED.CASILLAS@sakilacustomer.org	428	t	2006-02-14	2006-02-15 04:57:20	1
424	2	KYLE	SPURLOCK	KYLE.SPURLOCK@sakilacustomer.org	429	t	2006-02-14	2006-02-15 04:57:20	1
425	2	FRANCIS	SIKES	FRANCIS.SIKES@sakilacustomer.org	430	t	2006-02-14	2006-02-15 04:57:20	1
426	1	BRADLEY	MOTLEY	BRADLEY.MOTLEY@sakilacustomer.org	431	t	2006-02-14	2006-02-15 04:57:20	1
427	2	JESUS	MCCARTNEY	JESUS.MCCARTNEY@sakilacustomer.org	432	t	2006-02-14	2006-02-15 04:57:20	1
428	2	HERBERT	KRUGER	HERBERT.KRUGER@sakilacustomer.org	433	t	2006-02-14	2006-02-15 04:57:20	1
429	2	FREDERICK	ISBELL	FREDERICK.ISBELL@sakilacustomer.org	434	t	2006-02-14	2006-02-15 04:57:20	1
430	1	RAY	HOULE	RAY.HOULE@sakilacustomer.org	435	t	2006-02-14	2006-02-15 04:57:20	1
431	2	JOEL	FRANCISCO	JOEL.FRANCISCO@sakilacustomer.org	436	t	2006-02-14	2006-02-15 04:57:20	1
432	1	EDWIN	BURK	EDWIN.BURK@sakilacustomer.org	437	t	2006-02-14	2006-02-15 04:57:20	1
433	1	DON	BONE	DON.BONE@sakilacustomer.org	438	t	2006-02-14	2006-02-15 04:57:20	1
434	1	EDDIE	TOMLIN	EDDIE.TOMLIN@sakilacustomer.org	439	t	2006-02-14	2006-02-15 04:57:20	1
435	2	RICKY	SHELBY	RICKY.SHELBY@sakilacustomer.org	440	t	2006-02-14	2006-02-15 04:57:20	1
436	1	TROY	QUIGLEY	TROY.QUIGLEY@sakilacustomer.org	441	t	2006-02-14	2006-02-15 04:57:20	1
437	2	RANDALL	NEUMANN	RANDALL.NEUMANN@sakilacustomer.org	442	t	2006-02-14	2006-02-15 04:57:20	1
438	1	BARRY	LOVELACE	BARRY.LOVELACE@sakilacustomer.org	443	t	2006-02-14	2006-02-15 04:57:20	1
439	2	ALEXANDER	FENNELL	ALEXANDER.FENNELL@sakilacustomer.org	444	t	2006-02-14	2006-02-15 04:57:20	1
440	1	BERNARD	COLBY	BERNARD.COLBY@sakilacustomer.org	445	t	2006-02-14	2006-02-15 04:57:20	1
441	1	MARIO	CHEATHAM	MARIO.CHEATHAM@sakilacustomer.org	446	t	2006-02-14	2006-02-15 04:57:20	1
442	1	LEROY	BUSTAMANTE	LEROY.BUSTAMANTE@sakilacustomer.org	447	t	2006-02-14	2006-02-15 04:57:20	1
443	2	FRANCISCO	SKIDMORE	FRANCISCO.SKIDMORE@sakilacustomer.org	448	t	2006-02-14	2006-02-15 04:57:20	1
444	2	MARCUS	HIDALGO	MARCUS.HIDALGO@sakilacustomer.org	449	t	2006-02-14	2006-02-15 04:57:20	1
445	1	MICHEAL	FORMAN	MICHEAL.FORMAN@sakilacustomer.org	450	t	2006-02-14	2006-02-15 04:57:20	1
446	2	THEODORE	CULP	THEODORE.CULP@sakilacustomer.org	451	t	2006-02-14	2006-02-15 04:57:20	0
447	1	CLIFFORD	BOWENS	CLIFFORD.BOWENS@sakilacustomer.org	452	t	2006-02-14	2006-02-15 04:57:20	1
448	1	MIGUEL	BETANCOURT	MIGUEL.BETANCOURT@sakilacustomer.org	453	t	2006-02-14	2006-02-15 04:57:20	1
449	2	OSCAR	AQUINO	OSCAR.AQUINO@sakilacustomer.org	454	t	2006-02-14	2006-02-15 04:57:20	1
450	1	JAY	ROBB	JAY.ROBB@sakilacustomer.org	455	t	2006-02-14	2006-02-15 04:57:20	1
451	1	JIM	REA	JIM.REA@sakilacustomer.org	456	t	2006-02-14	2006-02-15 04:57:20	1
452	1	TOM	MILNER	TOM.MILNER@sakilacustomer.org	457	t	2006-02-14	2006-02-15 04:57:20	1
453	1	CALVIN	MARTEL	CALVIN.MARTEL@sakilacustomer.org	458	t	2006-02-14	2006-02-15 04:57:20	1
454	2	ALEX	GRESHAM	ALEX.GRESHAM@sakilacustomer.org	459	t	2006-02-14	2006-02-15 04:57:20	1
455	2	JON	WILES	JON.WILES@sakilacustomer.org	460	t	2006-02-14	2006-02-15 04:57:20	1
456	2	RONNIE	RICKETTS	RONNIE.RICKETTS@sakilacustomer.org	461	t	2006-02-14	2006-02-15 04:57:20	1
457	2	BILL	GAVIN	BILL.GAVIN@sakilacustomer.org	462	t	2006-02-14	2006-02-15 04:57:20	1
458	1	LLOYD	DOWD	LLOYD.DOWD@sakilacustomer.org	463	t	2006-02-14	2006-02-15 04:57:20	1
459	1	TOMMY	COLLAZO	TOMMY.COLLAZO@sakilacustomer.org	464	t	2006-02-14	2006-02-15 04:57:20	1
460	1	LEON	BOSTIC	LEON.BOSTIC@sakilacustomer.org	465	t	2006-02-14	2006-02-15 04:57:20	1
461	1	DEREK	BLAKELY	DEREK.BLAKELY@sakilacustomer.org	466	t	2006-02-14	2006-02-15 04:57:20	1
462	2	WARREN	SHERROD	WARREN.SHERROD@sakilacustomer.org	467	t	2006-02-14	2006-02-15 04:57:20	1
463	2	DARRELL	POWER	DARRELL.POWER@sakilacustomer.org	468	t	2006-02-14	2006-02-15 04:57:20	1
464	1	JEROME	KENYON	JEROME.KENYON@sakilacustomer.org	469	t	2006-02-14	2006-02-15 04:57:20	1
465	1	FLOYD	GANDY	FLOYD.GANDY@sakilacustomer.org	470	t	2006-02-14	2006-02-15 04:57:20	1
466	1	LEO	EBERT	LEO.EBERT@sakilacustomer.org	471	t	2006-02-14	2006-02-15 04:57:20	1
467	2	ALVIN	DELOACH	ALVIN.DELOACH@sakilacustomer.org	472	t	2006-02-14	2006-02-15 04:57:20	1
468	1	TIM	CARY	TIM.CARY@sakilacustomer.org	473	t	2006-02-14	2006-02-15 04:57:20	1
469	2	WESLEY	BULL	WESLEY.BULL@sakilacustomer.org	474	t	2006-02-14	2006-02-15 04:57:20	1
470	1	GORDON	ALLARD	GORDON.ALLARD@sakilacustomer.org	475	t	2006-02-14	2006-02-15 04:57:20	1
471	1	DEAN	SAUER	DEAN.SAUER@sakilacustomer.org	476	t	2006-02-14	2006-02-15 04:57:20	1
472	1	GREG	ROBINS	GREG.ROBINS@sakilacustomer.org	477	t	2006-02-14	2006-02-15 04:57:20	1
473	2	JORGE	OLIVARES	JORGE.OLIVARES@sakilacustomer.org	478	t	2006-02-14	2006-02-15 04:57:20	1
474	2	DUSTIN	GILLETTE	DUSTIN.GILLETTE@sakilacustomer.org	479	t	2006-02-14	2006-02-15 04:57:20	1
475	2	PEDRO	CHESTNUT	PEDRO.CHESTNUT@sakilacustomer.org	480	t	2006-02-14	2006-02-15 04:57:20	1
476	1	DERRICK	BOURQUE	DERRICK.BOURQUE@sakilacustomer.org	481	t	2006-02-14	2006-02-15 04:57:20	1
477	1	DAN	PAINE	DAN.PAINE@sakilacustomer.org	482	t	2006-02-14	2006-02-15 04:57:20	1
478	1	LEWIS	LYMAN	LEWIS.LYMAN@sakilacustomer.org	483	t	2006-02-14	2006-02-15 04:57:20	1
479	1	ZACHARY	HITE	ZACHARY.HITE@sakilacustomer.org	484	t	2006-02-14	2006-02-15 04:57:20	1
480	1	COREY	HAUSER	COREY.HAUSER@sakilacustomer.org	485	t	2006-02-14	2006-02-15 04:57:20	1
481	1	HERMAN	DEVORE	HERMAN.DEVORE@sakilacustomer.org	486	t	2006-02-14	2006-02-15 04:57:20	1
482	1	MAURICE	CRAWLEY	MAURICE.CRAWLEY@sakilacustomer.org	487	t	2006-02-14	2006-02-15 04:57:20	0
483	2	VERNON	CHAPA	VERNON.CHAPA@sakilacustomer.org	488	t	2006-02-14	2006-02-15 04:57:20	1
484	1	ROBERTO	VU	ROBERTO.VU@sakilacustomer.org	489	t	2006-02-14	2006-02-15 04:57:20	1
485	1	CLYDE	TOBIAS	CLYDE.TOBIAS@sakilacustomer.org	490	t	2006-02-14	2006-02-15 04:57:20	1
486	1	GLEN	TALBERT	GLEN.TALBERT@sakilacustomer.org	491	t	2006-02-14	2006-02-15 04:57:20	1
487	2	HECTOR	POINDEXTER	HECTOR.POINDEXTER@sakilacustomer.org	492	t	2006-02-14	2006-02-15 04:57:20	1
488	2	SHANE	MILLARD	SHANE.MILLARD@sakilacustomer.org	493	t	2006-02-14	2006-02-15 04:57:20	1
489	1	RICARDO	MEADOR	RICARDO.MEADOR@sakilacustomer.org	494	t	2006-02-14	2006-02-15 04:57:20	1
490	1	SAM	MCDUFFIE	SAM.MCDUFFIE@sakilacustomer.org	495	t	2006-02-14	2006-02-15 04:57:20	1
491	2	RICK	MATTOX	RICK.MATTOX@sakilacustomer.org	496	t	2006-02-14	2006-02-15 04:57:20	1
492	2	LESTER	KRAUS	LESTER.KRAUS@sakilacustomer.org	497	t	2006-02-14	2006-02-15 04:57:20	1
493	1	BRENT	HARKINS	BRENT.HARKINS@sakilacustomer.org	498	t	2006-02-14	2006-02-15 04:57:20	1
494	2	RAMON	CHOATE	RAMON.CHOATE@sakilacustomer.org	499	t	2006-02-14	2006-02-15 04:57:20	1
495	2	CHARLIE	BESS	CHARLIE.BESS@sakilacustomer.org	500	t	2006-02-14	2006-02-15 04:57:20	1
496	2	TYLER	WREN	TYLER.WREN@sakilacustomer.org	501	t	2006-02-14	2006-02-15 04:57:20	1
497	2	GILBERT	SLEDGE	GILBERT.SLEDGE@sakilacustomer.org	502	t	2006-02-14	2006-02-15 04:57:20	1
498	1	GENE	SANBORN	GENE.SANBORN@sakilacustomer.org	503	t	2006-02-14	2006-02-15 04:57:20	1
499	2	MARC	OUTLAW	MARC.OUTLAW@sakilacustomer.org	504	t	2006-02-14	2006-02-15 04:57:20	1
500	1	REGINALD	KINDER	REGINALD.KINDER@sakilacustomer.org	505	t	2006-02-14	2006-02-15 04:57:20	1
501	1	RUBEN	GEARY	RUBEN.GEARY@sakilacustomer.org	506	t	2006-02-14	2006-02-15 04:57:20	1
502	1	BRETT	CORNWELL	BRETT.CORNWELL@sakilacustomer.org	507	t	2006-02-14	2006-02-15 04:57:20	1
503	1	ANGEL	BARCLAY	ANGEL.BARCLAY@sakilacustomer.org	508	t	2006-02-14	2006-02-15 04:57:20	1
504	1	NATHANIEL	ADAM	NATHANIEL.ADAM@sakilacustomer.org	509	t	2006-02-14	2006-02-15 04:57:20	1
505	1	RAFAEL	ABNEY	RAFAEL.ABNEY@sakilacustomer.org	510	t	2006-02-14	2006-02-15 04:57:20	1
506	2	LESLIE	SEWARD	LESLIE.SEWARD@sakilacustomer.org	511	t	2006-02-14	2006-02-15 04:57:20	1
507	2	EDGAR	RHOADS	EDGAR.RHOADS@sakilacustomer.org	512	t	2006-02-14	2006-02-15 04:57:20	1
508	2	MILTON	HOWLAND	MILTON.HOWLAND@sakilacustomer.org	513	t	2006-02-14	2006-02-15 04:57:20	1
509	1	RAUL	FORTIER	RAUL.FORTIER@sakilacustomer.org	514	t	2006-02-14	2006-02-15 04:57:20	1
510	2	BEN	EASTER	BEN.EASTER@sakilacustomer.org	515	t	2006-02-14	2006-02-15 04:57:20	0
511	1	CHESTER	BENNER	CHESTER.BENNER@sakilacustomer.org	516	t	2006-02-14	2006-02-15 04:57:20	1
512	1	CECIL	VINES	CECIL.VINES@sakilacustomer.org	517	t	2006-02-14	2006-02-15 04:57:20	1
513	2	DUANE	TUBBS	DUANE.TUBBS@sakilacustomer.org	519	t	2006-02-14	2006-02-15 04:57:20	1
514	2	FRANKLIN	TROUTMAN	FRANKLIN.TROUTMAN@sakilacustomer.org	520	t	2006-02-14	2006-02-15 04:57:20	1
515	1	ANDRE	RAPP	ANDRE.RAPP@sakilacustomer.org	521	t	2006-02-14	2006-02-15 04:57:20	1
516	2	ELMER	NOE	ELMER.NOE@sakilacustomer.org	522	t	2006-02-14	2006-02-15 04:57:20	1
517	2	BRAD	MCCURDY	BRAD.MCCURDY@sakilacustomer.org	523	t	2006-02-14	2006-02-15 04:57:20	1
518	1	GABRIEL	HARDER	GABRIEL.HARDER@sakilacustomer.org	524	t	2006-02-14	2006-02-15 04:57:20	1
519	2	RON	DELUCA	RON.DELUCA@sakilacustomer.org	525	t	2006-02-14	2006-02-15 04:57:20	1
520	2	MITCHELL	WESTMORELAND	MITCHELL.WESTMORELAND@sakilacustomer.org	526	t	2006-02-14	2006-02-15 04:57:20	1
521	2	ROLAND	SOUTH	ROLAND.SOUTH@sakilacustomer.org	527	t	2006-02-14	2006-02-15 04:57:20	1
522	2	ARNOLD	HAVENS	ARNOLD.HAVENS@sakilacustomer.org	528	t	2006-02-14	2006-02-15 04:57:20	1
523	1	HARVEY	GUAJARDO	HARVEY.GUAJARDO@sakilacustomer.org	529	t	2006-02-14	2006-02-15 04:57:20	1
524	1	JARED	ELY	JARED.ELY@sakilacustomer.org	530	t	2006-02-14	2006-02-15 04:57:20	1
525	2	ADRIAN	CLARY	ADRIAN.CLARY@sakilacustomer.org	531	t	2006-02-14	2006-02-15 04:57:20	1
526	2	KARL	SEAL	KARL.SEAL@sakilacustomer.org	532	t	2006-02-14	2006-02-15 04:57:20	1
527	1	CORY	MEEHAN	CORY.MEEHAN@sakilacustomer.org	533	t	2006-02-14	2006-02-15 04:57:20	1
528	1	CLAUDE	HERZOG	CLAUDE.HERZOG@sakilacustomer.org	534	t	2006-02-14	2006-02-15 04:57:20	1
529	2	ERIK	GUILLEN	ERIK.GUILLEN@sakilacustomer.org	535	t	2006-02-14	2006-02-15 04:57:20	1
530	2	DARRYL	ASHCRAFT	DARRYL.ASHCRAFT@sakilacustomer.org	536	t	2006-02-14	2006-02-15 04:57:20	1
531	2	JAMIE	WAUGH	JAMIE.WAUGH@sakilacustomer.org	537	t	2006-02-14	2006-02-15 04:57:20	1
532	2	NEIL	RENNER	NEIL.RENNER@sakilacustomer.org	538	t	2006-02-14	2006-02-15 04:57:20	1
533	1	JESSIE	MILAM	JESSIE.MILAM@sakilacustomer.org	539	t	2006-02-14	2006-02-15 04:57:20	1
534	1	CHRISTIAN	JUNG	CHRISTIAN.JUNG@sakilacustomer.org	540	t	2006-02-14	2006-02-15 04:57:20	0
535	1	JAVIER	ELROD	JAVIER.ELROD@sakilacustomer.org	541	t	2006-02-14	2006-02-15 04:57:20	1
536	2	FERNANDO	CHURCHILL	FERNANDO.CHURCHILL@sakilacustomer.org	542	t	2006-02-14	2006-02-15 04:57:20	1
537	2	CLINTON	BUFORD	CLINTON.BUFORD@sakilacustomer.org	543	t	2006-02-14	2006-02-15 04:57:20	1
538	2	TED	BREAUX	TED.BREAUX@sakilacustomer.org	544	t	2006-02-14	2006-02-15 04:57:20	1
539	1	MATHEW	BOLIN	MATHEW.BOLIN@sakilacustomer.org	545	t	2006-02-14	2006-02-15 04:57:20	1
540	1	TYRONE	ASHER	TYRONE.ASHER@sakilacustomer.org	546	t	2006-02-14	2006-02-15 04:57:20	1
541	2	DARREN	WINDHAM	DARREN.WINDHAM@sakilacustomer.org	547	t	2006-02-14	2006-02-15 04:57:20	1
542	2	LONNIE	TIRADO	LONNIE.TIRADO@sakilacustomer.org	548	t	2006-02-14	2006-02-15 04:57:20	1
543	1	LANCE	PEMBERTON	LANCE.PEMBERTON@sakilacustomer.org	549	t	2006-02-14	2006-02-15 04:57:20	1
544	2	CODY	NOLEN	CODY.NOLEN@sakilacustomer.org	550	t	2006-02-14	2006-02-15 04:57:20	1
545	2	JULIO	NOLAND	JULIO.NOLAND@sakilacustomer.org	551	t	2006-02-14	2006-02-15 04:57:20	1
546	1	KELLY	KNOTT	KELLY.KNOTT@sakilacustomer.org	552	t	2006-02-14	2006-02-15 04:57:20	1
547	1	KURT	EMMONS	KURT.EMMONS@sakilacustomer.org	553	t	2006-02-14	2006-02-15 04:57:20	1
548	1	ALLAN	CORNISH	ALLAN.CORNISH@sakilacustomer.org	554	t	2006-02-14	2006-02-15 04:57:20	1
549	1	NELSON	CHRISTENSON	NELSON.CHRISTENSON@sakilacustomer.org	555	t	2006-02-14	2006-02-15 04:57:20	1
550	2	GUY	BROWNLEE	GUY.BROWNLEE@sakilacustomer.org	556	t	2006-02-14	2006-02-15 04:57:20	1
551	2	CLAYTON	BARBEE	CLAYTON.BARBEE@sakilacustomer.org	557	t	2006-02-14	2006-02-15 04:57:20	1
552	2	HUGH	WALDROP	HUGH.WALDROP@sakilacustomer.org	558	t	2006-02-14	2006-02-15 04:57:20	1
553	1	MAX	PITT	MAX.PITT@sakilacustomer.org	559	t	2006-02-14	2006-02-15 04:57:20	1
554	1	DWAYNE	OLVERA	DWAYNE.OLVERA@sakilacustomer.org	560	t	2006-02-14	2006-02-15 04:57:20	1
555	1	DWIGHT	LOMBARDI	DWIGHT.LOMBARDI@sakilacustomer.org	561	t	2006-02-14	2006-02-15 04:57:20	1
556	2	ARMANDO	GRUBER	ARMANDO.GRUBER@sakilacustomer.org	562	t	2006-02-14	2006-02-15 04:57:20	1
557	1	FELIX	GAFFNEY	FELIX.GAFFNEY@sakilacustomer.org	563	t	2006-02-14	2006-02-15 04:57:20	1
558	1	JIMMIE	EGGLESTON	JIMMIE.EGGLESTON@sakilacustomer.org	564	t	2006-02-14	2006-02-15 04:57:20	0
559	2	EVERETT	BANDA	EVERETT.BANDA@sakilacustomer.org	565	t	2006-02-14	2006-02-15 04:57:20	1
560	1	JORDAN	ARCHULETA	JORDAN.ARCHULETA@sakilacustomer.org	566	t	2006-02-14	2006-02-15 04:57:20	1
561	2	IAN	STILL	IAN.STILL@sakilacustomer.org	567	t	2006-02-14	2006-02-15 04:57:20	1
562	1	WALLACE	SLONE	WALLACE.SLONE@sakilacustomer.org	568	t	2006-02-14	2006-02-15 04:57:20	1
563	2	KEN	PREWITT	KEN.PREWITT@sakilacustomer.org	569	t	2006-02-14	2006-02-15 04:57:20	1
564	2	BOB	PFEIFFER	BOB.PFEIFFER@sakilacustomer.org	570	t	2006-02-14	2006-02-15 04:57:20	1
565	2	JAIME	NETTLES	JAIME.NETTLES@sakilacustomer.org	571	t	2006-02-14	2006-02-15 04:57:20	1
566	1	CASEY	MENA	CASEY.MENA@sakilacustomer.org	572	t	2006-02-14	2006-02-15 04:57:20	1
567	2	ALFREDO	MCADAMS	ALFREDO.MCADAMS@sakilacustomer.org	573	t	2006-02-14	2006-02-15 04:57:20	1
568	2	ALBERTO	HENNING	ALBERTO.HENNING@sakilacustomer.org	574	t	2006-02-14	2006-02-15 04:57:20	1
569	2	DAVE	GARDINER	DAVE.GARDINER@sakilacustomer.org	575	t	2006-02-14	2006-02-15 04:57:20	1
570	2	IVAN	CROMWELL	IVAN.CROMWELL@sakilacustomer.org	576	t	2006-02-14	2006-02-15 04:57:20	1
571	2	JOHNNIE	CHISHOLM	JOHNNIE.CHISHOLM@sakilacustomer.org	577	t	2006-02-14	2006-02-15 04:57:20	1
572	1	SIDNEY	BURLESON	SIDNEY.BURLESON@sakilacustomer.org	578	t	2006-02-14	2006-02-15 04:57:20	1
573	1	BYRON	BOX	BYRON.BOX@sakilacustomer.org	579	t	2006-02-14	2006-02-15 04:57:20	1
574	2	JULIAN	VEST	JULIAN.VEST@sakilacustomer.org	580	t	2006-02-14	2006-02-15 04:57:20	1
575	2	ISAAC	OGLESBY	ISAAC.OGLESBY@sakilacustomer.org	581	t	2006-02-14	2006-02-15 04:57:20	1
576	2	MORRIS	MCCARTER	MORRIS.MCCARTER@sakilacustomer.org	582	t	2006-02-14	2006-02-15 04:57:20	1
577	2	CLIFTON	MALCOLM	CLIFTON.MALCOLM@sakilacustomer.org	583	t	2006-02-14	2006-02-15 04:57:20	1
578	2	WILLARD	LUMPKIN	WILLARD.LUMPKIN@sakilacustomer.org	584	t	2006-02-14	2006-02-15 04:57:20	1
579	2	DARYL	LARUE	DARYL.LARUE@sakilacustomer.org	585	t	2006-02-14	2006-02-15 04:57:20	1
580	1	ROSS	GREY	ROSS.GREY@sakilacustomer.org	586	t	2006-02-14	2006-02-15 04:57:20	1
581	1	VIRGIL	WOFFORD	VIRGIL.WOFFORD@sakilacustomer.org	587	t	2006-02-14	2006-02-15 04:57:20	1
582	2	ANDY	VANHORN	ANDY.VANHORN@sakilacustomer.org	588	t	2006-02-14	2006-02-15 04:57:20	1
583	1	MARSHALL	THORN	MARSHALL.THORN@sakilacustomer.org	589	t	2006-02-14	2006-02-15 04:57:20	1
584	2	SALVADOR	TEEL	SALVADOR.TEEL@sakilacustomer.org	590	t	2006-02-14	2006-02-15 04:57:20	1
585	1	PERRY	SWAFFORD	PERRY.SWAFFORD@sakilacustomer.org	591	t	2006-02-14	2006-02-15 04:57:20	1
586	1	KIRK	STCLAIR	KIRK.STCLAIR@sakilacustomer.org	592	t	2006-02-14	2006-02-15 04:57:20	1
587	1	SERGIO	STANFIELD	SERGIO.STANFIELD@sakilacustomer.org	593	t	2006-02-14	2006-02-15 04:57:20	1
588	1	MARION	OCAMPO	MARION.OCAMPO@sakilacustomer.org	594	t	2006-02-14	2006-02-15 04:57:20	1
589	1	TRACY	HERRMANN	TRACY.HERRMANN@sakilacustomer.org	595	t	2006-02-14	2006-02-15 04:57:20	1
590	2	SETH	HANNON	SETH.HANNON@sakilacustomer.org	596	t	2006-02-14	2006-02-15 04:57:20	1
591	1	KENT	ARSENAULT	KENT.ARSENAULT@sakilacustomer.org	597	t	2006-02-14	2006-02-15 04:57:20	1
592	1	TERRANCE	ROUSH	TERRANCE.ROUSH@sakilacustomer.org	598	t	2006-02-14	2006-02-15 04:57:20	0
593	2	RENE	MCALISTER	RENE.MCALISTER@sakilacustomer.org	599	t	2006-02-14	2006-02-15 04:57:20	1
594	1	EDUARDO	HIATT	EDUARDO.HIATT@sakilacustomer.org	600	t	2006-02-14	2006-02-15 04:57:20	1
595	1	TERRENCE	GUNDERSON	TERRENCE.GUNDERSON@sakilacustomer.org	601	t	2006-02-14	2006-02-15 04:57:20	1
596	1	ENRIQUE	FORSYTHE	ENRIQUE.FORSYTHE@sakilacustomer.org	602	t	2006-02-14	2006-02-15 04:57:20	1
597	1	FREDDIE	DUGGAN	FREDDIE.DUGGAN@sakilacustomer.org	603	t	2006-02-14	2006-02-15 04:57:20	1
598	1	WADE	DELVALLE	WADE.DELVALLE@sakilacustomer.org	604	t	2006-02-14	2006-02-15 04:57:20	1
599	2	AUSTIN	CINTRON	AUSTIN.CINTRON@sakilacustomer.org	605	t	2006-02-14	2006-02-15 04:57:20	1
\.


--
-- Data for Name: film; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.film (film_id, title, description, release_year, language_id, original_language_id, rental_duration, rental_rate, length, replacement_cost, rating, last_update, special_features, fulltext) FROM stdin;
1	ACADEMY DINOSAUR	A Epic Drama of a Feminist And a Mad Scientist who must Battle a Teacher in The Canadian Rockies	2006	1	\N	6	0.99	86	20.99	PG	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'academi':1 'battl':15 'canadian':20 'dinosaur':2 'drama':5 'epic':4 'feminist':8 'mad':11 'must':14 'rocki':21 'scientist':12 'teacher':17
2	ACE GOLDFINGER	A Astounding Epistle of a Database Administrator And a Explorer who must Find a Car in Ancient China	2006	1	\N	3	4.99	48	12.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'ace':1 'administr':9 'ancient':19 'astound':4 'car':17 'china':20 'databas':8 'epistl':5 'explor':12 'find':15 'goldfing':2 'must':14
3	ADAPTATION HOLES	A Astounding Reflection of a Lumberjack And a Car who must Sink a Lumberjack in A Baloon Factory	2006	1	\N	7	2.99	50	18.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'adapt':1 'astound':4 'baloon':19 'car':11 'factori':20 'hole':2 'lumberjack':8,16 'must':13 'reflect':5 'sink':14
4	AFFAIR PREJUDICE	A Fanciful Documentary of a Frisbee And a Lumberjack who must Chase a Monkey in A Shark Tank	2006	1	\N	5	2.99	117	26.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'affair':1 'chase':14 'documentari':5 'fanci':4 'frisbe':8 'lumberjack':11 'monkey':16 'must':13 'prejudic':2 'shark':19 'tank':20
5	AFRICAN EGG	A Fast-Paced Documentary of a Pastry Chef And a Dentist who must Pursue a Forensic Psychologist in The Gulf of Mexico	2006	1	\N	6	2.99	130	22.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'african':1 'chef':11 'dentist':14 'documentari':7 'egg':2 'fast':5 'fast-pac':4 'forens':19 'gulf':23 'mexico':25 'must':16 'pace':6 'pastri':10 'psychologist':20 'pursu':17
6	AGENT TRUMAN	A Intrepid Panorama of a Robot And a Boy who must Escape a Sumo Wrestler in Ancient China	2006	1	\N	3	2.99	169	17.99	PG	2006-02-15 05:03:42	{"Deleted Scenes"}	'agent':1 'ancient':19 'boy':11 'china':20 'escap':14 'intrepid':4 'must':13 'panorama':5 'robot':8 'sumo':16 'truman':2 'wrestler':17
7	AIRPLANE SIERRA	A Touching Saga of a Hunter And a Butler who must Discover a Butler in A Jet Boat	2006	1	\N	6	4.99	62	28.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'airplan':1 'boat':20 'butler':11,16 'discov':14 'hunter':8 'jet':19 'must':13 'saga':5 'sierra':2 'touch':4
8	AIRPORT POLLOCK	A Epic Tale of a Moose And a Girl who must Confront a Monkey in Ancient India	2006	1	\N	6	4.99	54	15.99	R	2006-02-15 05:03:42	{Trailers}	'airport':1 'ancient':18 'confront':14 'epic':4 'girl':11 'india':19 'monkey':16 'moos':8 'must':13 'pollock':2 'tale':5
9	ALABAMA DEVIL	A Thoughtful Panorama of a Database Administrator And a Mad Scientist who must Outgun a Mad Scientist in A Jet Boat	2006	1	\N	3	2.99	114	21.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'administr':9 'alabama':1 'boat':23 'databas':8 'devil':2 'jet':22 'mad':12,18 'must':15 'outgun':16 'panorama':5 'scientist':13,19 'thought':4
10	ALADDIN CALENDAR	A Action-Packed Tale of a Man And a Lumberjack who must Reach a Feminist in Ancient China	2006	1	\N	6	4.99	63	24.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'action':5 'action-pack':4 'aladdin':1 'ancient':20 'calendar':2 'china':21 'feminist':18 'lumberjack':13 'man':10 'must':15 'pack':6 'reach':16 'tale':7
11	ALAMO VIDEOTAPE	A Boring Epistle of a Butler And a Cat who must Fight a Pastry Chef in A MySQL Convention	2006	1	\N	6	0.99	126	16.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'alamo':1 'bore':4 'butler':8 'cat':11 'chef':17 'convent':21 'epistl':5 'fight':14 'must':13 'mysql':20 'pastri':16 'videotap':2
12	ALASKA PHANTOM	A Fanciful Saga of a Hunter And a Pastry Chef who must Vanquish a Boy in Australia	2006	1	\N	6	0.99	136	22.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'alaska':1 'australia':19 'boy':17 'chef':12 'fanci':4 'hunter':8 'must':14 'pastri':11 'phantom':2 'saga':5 'vanquish':15
13	ALI FOREVER	A Action-Packed Drama of a Dentist And a Crocodile who must Battle a Feminist in The Canadian Rockies	2006	1	\N	4	4.99	150	21.99	PG	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'action':5 'action-pack':4 'ali':1 'battl':16 'canadian':21 'crocodil':13 'dentist':10 'drama':7 'feminist':18 'forev':2 'must':15 'pack':6 'rocki':22
14	ALICE FANTASIA	A Emotional Drama of a A Shark And a Database Administrator who must Vanquish a Pioneer in Soviet Georgia	2006	1	\N	6	0.99	94	23.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'administr':13 'alic':1 'databas':12 'drama':5 'emot':4 'fantasia':2 'georgia':21 'must':15 'pioneer':18 'shark':9 'soviet':20 'vanquish':16
15	ALIEN CENTER	A Brilliant Drama of a Cat And a Mad Scientist who must Battle a Feminist in A MySQL Convention	2006	1	\N	5	2.99	46	10.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'alien':1 'battl':15 'brilliant':4 'cat':8 'center':2 'convent':21 'drama':5 'feminist':17 'mad':11 'must':14 'mysql':20 'scientist':12
16	ALLEY EVOLUTION	A Fast-Paced Drama of a Robot And a Composer who must Battle a Astronaut in New Orleans	2006	1	\N	6	2.99	180	23.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries}	'alley':1 'astronaut':18 'battl':16 'compos':13 'drama':7 'evolut':2 'fast':5 'fast-pac':4 'must':15 'new':20 'orlean':21 'pace':6 'robot':10
17	ALONE TRIP	A Fast-Paced Character Study of a Composer And a Dog who must Outgun a Boat in An Abandoned Fun House	2006	1	\N	3	0.99	82	14.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'abandon':22 'alon':1 'boat':19 'charact':7 'compos':11 'dog':14 'fast':5 'fast-pac':4 'fun':23 'hous':24 'must':16 'outgun':17 'pace':6 'studi':8 'trip':2
18	ALTER VICTORY	A Thoughtful Drama of a Composer And a Feminist who must Meet a Secret Agent in The Canadian Rockies	2006	1	\N	6	0.99	57	27.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'agent':17 'alter':1 'canadian':20 'compos':8 'drama':5 'feminist':11 'meet':14 'must':13 'rocki':21 'secret':16 'thought':4 'victori':2
19	AMADEUS HOLY	A Emotional Display of a Pioneer And a Technical Writer who must Battle a Man in A Baloon	2006	1	\N	6	0.99	113	20.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'amadeus':1 'baloon':20 'battl':15 'display':5 'emot':4 'holi':2 'man':17 'must':14 'pioneer':8 'technic':11 'writer':12
20	AMELIE HELLFIGHTERS	A Boring Drama of a Woman And a Squirrel who must Conquer a Student in A Baloon	2006	1	\N	4	4.99	79	23.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'ameli':1 'baloon':19 'bore':4 'conquer':14 'drama':5 'hellfight':2 'must':13 'squirrel':11 'student':16 'woman':8
21	AMERICAN CIRCUS	A Insightful Drama of a Girl And a Astronaut who must Face a Database Administrator in A Shark Tank	2006	1	\N	3	4.99	129	17.99	R	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'administr':17 'american':1 'astronaut':11 'circus':2 'databas':16 'drama':5 'face':14 'girl':8 'insight':4 'must':13 'shark':20 'tank':21
22	AMISTAD MIDSUMMER	A Emotional Character Study of a Dentist And a Crocodile who must Meet a Sumo Wrestler in California	2006	1	\N	6	2.99	85	10.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'amistad':1 'california':20 'charact':5 'crocodil':12 'dentist':9 'emot':4 'meet':15 'midsumm':2 'must':14 'studi':6 'sumo':17 'wrestler':18
23	ANACONDA CONFESSIONS	A Lacklusture Display of a Dentist And a Dentist who must Fight a Girl in Australia	2006	1	\N	3	0.99	92	9.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'anaconda':1 'australia':18 'confess':2 'dentist':8,11 'display':5 'fight':14 'girl':16 'lacklustur':4 'must':13
24	ANALYZE HOOSIERS	A Thoughtful Display of a Explorer And a Pastry Chef who must Overcome a Feminist in The Sahara Desert	2006	1	\N	6	2.99	181	19.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'analyz':1 'chef':12 'desert':21 'display':5 'explor':8 'feminist':17 'hoosier':2 'must':14 'overcom':15 'pastri':11 'sahara':20 'thought':4
25	ANGELS LIFE	A Thoughtful Display of a Woman And a Astronaut who must Battle a Robot in Berlin	2006	1	\N	3	2.99	74	15.99	G	2006-02-15 05:03:42	{Trailers}	'angel':1 'astronaut':11 'battl':14 'berlin':18 'display':5 'life':2 'must':13 'robot':16 'thought':4 'woman':8
26	ANNIE IDENTITY	A Amazing Panorama of a Pastry Chef And a Boat who must Escape a Woman in An Abandoned Amusement Park	2006	1	\N	3	0.99	86	15.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'abandon':20 'amaz':4 'amus':21 'anni':1 'boat':12 'chef':9 'escap':15 'ident':2 'must':14 'panorama':5 'park':22 'pastri':8 'woman':17
27	ANONYMOUS HUMAN	A Amazing Reflection of a Database Administrator And a Astronaut who must Outrace a Database Administrator in A Shark Tank	2006	1	\N	7	0.99	179	12.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'administr':9,18 'amaz':4 'anonym':1 'astronaut':12 'databas':8,17 'human':2 'must':14 'outrac':15 'reflect':5 'shark':21 'tank':22
28	ANTHEM LUKE	A Touching Panorama of a Waitress And a Woman who must Outrace a Dog in An Abandoned Amusement Park	2006	1	\N	5	4.99	91	16.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'abandon':19 'amus':20 'anthem':1 'dog':16 'luke':2 'must':13 'outrac':14 'panorama':5 'park':21 'touch':4 'waitress':8 'woman':11
29	ANTITRUST TOMATOES	A Fateful Yarn of a Womanizer And a Feminist who must Succumb a Database Administrator in Ancient India	2006	1	\N	5	2.99	168	11.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'administr':17 'ancient':19 'antitrust':1 'databas':16 'fate':4 'feminist':11 'india':20 'must':13 'succumb':14 'tomato':2 'woman':8 'yarn':5
30	ANYTHING SAVANNAH	A Epic Story of a Pastry Chef And a Woman who must Chase a Feminist in An Abandoned Fun House	2006	1	\N	4	2.99	82	27.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'abandon':20 'anyth':1 'chase':15 'chef':9 'epic':4 'feminist':17 'fun':21 'hous':22 'must':14 'pastri':8 'savannah':2 'stori':5 'woman':12
31	APACHE DIVINE	A Awe-Inspiring Reflection of a Pastry Chef And a Teacher who must Overcome a Sumo Wrestler in A U-Boat	2006	1	\N	5	4.99	92	16.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'apach':1 'awe':5 'awe-inspir':4 'boat':25 'chef':11 'divin':2 'inspir':6 'must':16 'overcom':17 'pastri':10 'reflect':7 'sumo':19 'teacher':14 'u':24 'u-boat':23 'wrestler':20
32	APOCALYPSE FLAMINGOS	A Astounding Story of a Dog And a Squirrel who must Defeat a Woman in An Abandoned Amusement Park	2006	1	\N	6	4.99	119	11.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'abandon':19 'amus':20 'apocalyps':1 'astound':4 'defeat':14 'dog':8 'flamingo':2 'must':13 'park':21 'squirrel':11 'stori':5 'woman':16
33	APOLLO TEEN	A Action-Packed Reflection of a Crocodile And a Explorer who must Find a Sumo Wrestler in An Abandoned Mine Shaft	2006	1	\N	5	2.99	153	15.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':22 'action':5 'action-pack':4 'apollo':1 'crocodil':10 'explor':13 'find':16 'mine':23 'must':15 'pack':6 'reflect':7 'shaft':24 'sumo':18 'teen':2 'wrestler':19
34	ARABIA DOGMA	A Touching Epistle of a Madman And a Mad Cow who must Defeat a Student in Nigeria	2006	1	\N	6	0.99	62	29.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'arabia':1 'cow':12 'defeat':15 'dogma':2 'epistl':5 'mad':11 'madman':8 'must':14 'nigeria':19 'student':17 'touch':4
35	ARACHNOPHOBIA ROLLERCOASTER	A Action-Packed Reflection of a Pastry Chef And a Composer who must Discover a Mad Scientist in The First Manned Space Station	2006	1	\N	4	2.99	147	24.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'action':5 'action-pack':4 'arachnophobia':1 'chef':11 'compos':14 'discov':17 'first':23 'mad':19 'man':24 'must':16 'pack':6 'pastri':10 'reflect':7 'rollercoast':2 'scientist':20 'space':25 'station':26
36	ARGONAUTS TOWN	A Emotional Epistle of a Forensic Psychologist And a Butler who must Challenge a Waitress in An Abandoned Mine Shaft	2006	1	\N	7	0.99	127	12.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'abandon':20 'argonaut':1 'butler':12 'challeng':15 'emot':4 'epistl':5 'forens':8 'mine':21 'must':14 'psychologist':9 'shaft':22 'town':2 'waitress':17
37	ARIZONA BANG	A Brilliant Panorama of a Mad Scientist And a Mad Cow who must Meet a Pioneer in A Monastery	2006	1	\N	3	2.99	121	28.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'arizona':1 'bang':2 'brilliant':4 'cow':13 'mad':8,12 'meet':16 'monasteri':21 'must':15 'panorama':5 'pioneer':18 'scientist':9
38	ARK RIDGEMONT	A Beautiful Yarn of a Pioneer And a Monkey who must Pursue a Explorer in The Sahara Desert	2006	1	\N	6	0.99	68	25.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'ark':1 'beauti':4 'desert':20 'explor':16 'monkey':11 'must':13 'pioneer':8 'pursu':14 'ridgemont':2 'sahara':19 'yarn':5
39	ARMAGEDDON LOST	A Fast-Paced Tale of a Boat And a Teacher who must Succumb a Composer in An Abandoned Mine Shaft	2006	1	\N	5	0.99	99	10.99	G	2006-02-15 05:03:42	{Trailers}	'abandon':21 'armageddon':1 'boat':10 'compos':18 'fast':5 'fast-pac':4 'lost':2 'mine':22 'must':15 'pace':6 'shaft':23 'succumb':16 'tale':7 'teacher':13
40	ARMY FLINTSTONES	A Boring Saga of a Database Administrator And a Womanizer who must Battle a Waitress in Nigeria	2006	1	\N	4	0.99	148	22.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'administr':9 'armi':1 'battl':15 'bore':4 'databas':8 'flintston':2 'must':14 'nigeria':19 'saga':5 'waitress':17 'woman':12
41	ARSENIC INDEPENDENCE	A Fanciful Documentary of a Mad Cow And a Womanizer who must Find a Dentist in Berlin	2006	1	\N	4	0.99	137	17.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'arsenic':1 'berlin':19 'cow':9 'dentist':17 'documentari':5 'fanci':4 'find':15 'independ':2 'mad':8 'must':14 'woman':12
42	ARTIST COLDBLOODED	A Stunning Reflection of a Robot And a Moose who must Challenge a Woman in California	2006	1	\N	5	2.99	170	10.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'artist':1 'california':18 'challeng':14 'coldblood':2 'moos':11 'must':13 'reflect':5 'robot':8 'stun':4 'woman':16
43	ATLANTIS CAUSE	A Thrilling Yarn of a Feminist And a Hunter who must Fight a Technical Writer in A Shark Tank	2006	1	\N	6	2.99	170	15.99	G	2006-02-15 05:03:42	{"Behind the Scenes"}	'atlanti':1 'caus':2 'feminist':8 'fight':14 'hunter':11 'must':13 'shark':20 'tank':21 'technic':16 'thrill':4 'writer':17 'yarn':5
44	ATTACKS HATE	A Fast-Paced Panorama of a Technical Writer And a Mad Scientist who must Find a Feminist in An Abandoned Mine Shaft	2006	1	\N	5	4.99	113	21.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'abandon':23 'attack':1 'fast':5 'fast-pac':4 'feminist':20 'find':18 'hate':2 'mad':14 'mine':24 'must':17 'pace':6 'panorama':7 'scientist':15 'shaft':25 'technic':10 'writer':11
45	ATTRACTION NEWTON	A Astounding Panorama of a Composer And a Frisbee who must Reach a Husband in Ancient Japan	2006	1	\N	5	4.99	83	14.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'ancient':18 'astound':4 'attract':1 'compos':8 'frisbe':11 'husband':16 'japan':19 'must':13 'newton':2 'panorama':5 'reach':14
46	AUTUMN CROW	A Beautiful Tale of a Dentist And a Mad Cow who must Battle a Moose in The Sahara Desert	2006	1	\N	3	4.99	108	13.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'autumn':1 'battl':15 'beauti':4 'cow':12 'crow':2 'dentist':8 'desert':21 'mad':11 'moos':17 'must':14 'sahara':20 'tale':5
47	BABY HALL	A Boring Character Study of a A Shark And a Girl who must Outrace a Feminist in An Abandoned Mine Shaft	2006	1	\N	5	4.99	153	23.99	NC-17	2006-02-15 05:03:42	{Commentaries}	'abandon':21 'babi':1 'bore':4 'charact':5 'feminist':18 'girl':13 'hall':2 'mine':22 'must':15 'outrac':16 'shaft':23 'shark':10 'studi':6
48	BACKLASH UNDEFEATED	A Stunning Character Study of a Mad Scientist And a Mad Cow who must Kill a Car in A Monastery	2006	1	\N	3	4.99	118	24.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'backlash':1 'car':19 'charact':5 'cow':14 'kill':17 'mad':9,13 'monasteri':22 'must':16 'scientist':10 'studi':6 'stun':4 'undef':2
49	BADMAN DAWN	A Emotional Panorama of a Pioneer And a Composer who must Escape a Mad Scientist in A Jet Boat	2006	1	\N	6	2.99	162	22.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'badman':1 'boat':21 'compos':11 'dawn':2 'emot':4 'escap':14 'jet':20 'mad':16 'must':13 'panorama':5 'pioneer':8 'scientist':17
50	BAKED CLEOPATRA	A Stunning Drama of a Forensic Psychologist And a Husband who must Overcome a Waitress in A Monastery	2006	1	\N	3	2.99	182	20.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'bake':1 'cleopatra':2 'drama':5 'forens':8 'husband':12 'monasteri':20 'must':14 'overcom':15 'psychologist':9 'stun':4 'waitress':17
51	BALLOON HOMEWARD	A Insightful Panorama of a Forensic Psychologist And a Mad Cow who must Build a Mad Scientist in The First Manned Space Station	2006	1	\N	5	2.99	75	10.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes"}	'balloon':1 'build':16 'cow':13 'first':22 'forens':8 'homeward':2 'insight':4 'mad':12,18 'man':23 'must':15 'panorama':5 'psychologist':9 'scientist':19 'space':24 'station':25
52	BALLROOM MOCKINGBIRD	A Thrilling Documentary of a Composer And a Monkey who must Find a Feminist in California	2006	1	\N	6	0.99	173	29.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'ballroom':1 'california':18 'compos':8 'documentari':5 'feminist':16 'find':14 'mockingbird':2 'monkey':11 'must':13 'thrill':4
53	BANG KWAI	A Epic Drama of a Madman And a Cat who must Face a A Shark in An Abandoned Amusement Park	2006	1	\N	5	2.99	87	25.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':20 'amus':21 'bang':1 'cat':11 'drama':5 'epic':4 'face':14 'kwai':2 'madman':8 'must':13 'park':22 'shark':17
54	BANGER PINOCCHIO	A Awe-Inspiring Drama of a Car And a Pastry Chef who must Chase a Crocodile in The First Manned Space Station	2006	1	\N	5	0.99	113	15.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'awe':5 'awe-inspir':4 'banger':1 'car':10 'chase':17 'chef':14 'crocodil':19 'drama':7 'first':22 'inspir':6 'man':23 'must':16 'pastri':13 'pinocchio':2 'space':24 'station':25
55	BARBARELLA STREETCAR	A Awe-Inspiring Story of a Feminist And a Cat who must Conquer a Dog in A Monastery	2006	1	\N	6	2.99	65	27.99	G	2006-02-15 05:03:42	{"Behind the Scenes"}	'awe':5 'awe-inspir':4 'barbarella':1 'cat':13 'conquer':16 'dog':18 'feminist':10 'inspir':6 'monasteri':21 'must':15 'stori':7 'streetcar':2
56	BAREFOOT MANCHURIAN	A Intrepid Story of a Cat And a Student who must Vanquish a Girl in An Abandoned Amusement Park	2006	1	\N	6	2.99	129	15.99	G	2006-02-15 05:03:42	{Trailers,Commentaries}	'abandon':19 'amus':20 'barefoot':1 'cat':8 'girl':16 'intrepid':4 'manchurian':2 'must':13 'park':21 'stori':5 'student':11 'vanquish':14
57	BASIC EASY	A Stunning Epistle of a Man And a Husband who must Reach a Mad Scientist in A Jet Boat	2006	1	\N	4	2.99	90	18.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'basic':1 'boat':21 'easi':2 'epistl':5 'husband':11 'jet':20 'mad':16 'man':8 'must':13 'reach':14 'scientist':17 'stun':4
58	BEACH HEARTBREAKERS	A Fateful Display of a Womanizer And a Mad Scientist who must Outgun a A Shark in Soviet Georgia	2006	1	\N	6	2.99	122	16.99	G	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'beach':1 'display':5 'fate':4 'georgia':21 'heartbreak':2 'mad':11 'must':14 'outgun':15 'scientist':12 'shark':18 'soviet':20 'woman':8
59	BEAR GRACELAND	A Astounding Saga of a Dog And a Boy who must Kill a Teacher in The First Manned Space Station	2006	1	\N	4	2.99	160	20.99	R	2006-02-15 05:03:42	{"Deleted Scenes"}	'astound':4 'bear':1 'boy':11 'dog':8 'first':19 'graceland':2 'kill':14 'man':20 'must':13 'saga':5 'space':21 'station':22 'teacher':16
60	BEAST HUNCHBACK	A Awe-Inspiring Epistle of a Student And a Squirrel who must Defeat a Boy in Ancient China	2006	1	\N	3	4.99	89	22.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'ancient':20 'awe':5 'awe-inspir':4 'beast':1 'boy':18 'china':21 'defeat':16 'epistl':7 'hunchback':2 'inspir':6 'must':15 'squirrel':13 'student':10
61	BEAUTY GREASE	A Fast-Paced Display of a Composer And a Moose who must Sink a Robot in An Abandoned Mine Shaft	2006	1	\N	5	4.99	175	28.99	G	2006-02-15 05:03:42	{Trailers,Commentaries}	'abandon':21 'beauti':1 'compos':10 'display':7 'fast':5 'fast-pac':4 'greas':2 'mine':22 'moos':13 'must':15 'pace':6 'robot':18 'shaft':23 'sink':16
62	BED HIGHBALL	A Astounding Panorama of a Lumberjack And a Dog who must Redeem a Woman in An Abandoned Fun House	2006	1	\N	5	2.99	106	23.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'abandon':19 'astound':4 'bed':1 'dog':11 'fun':20 'highbal':2 'hous':21 'lumberjack':8 'must':13 'panorama':5 'redeem':14 'woman':16
63	BEDAZZLED MARRIED	A Astounding Character Study of a Madman And a Robot who must Meet a Mad Scientist in An Abandoned Fun House	2006	1	\N	6	0.99	73	21.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'abandon':21 'astound':4 'bedazzl':1 'charact':5 'fun':22 'hous':23 'mad':17 'madman':9 'marri':2 'meet':15 'must':14 'robot':12 'scientist':18 'studi':6
64	BEETHOVEN EXORCIST	A Epic Display of a Pioneer And a Student who must Challenge a Butler in The Gulf of Mexico	2006	1	\N	6	0.99	151	26.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'beethoven':1 'butler':16 'challeng':14 'display':5 'epic':4 'exorcist':2 'gulf':19 'mexico':21 'must':13 'pioneer':8 'student':11
65	BEHAVIOR RUNAWAY	A Unbelieveable Drama of a Student And a Husband who must Outrace a Sumo Wrestler in Berlin	2006	1	\N	3	4.99	100	20.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'behavior':1 'berlin':19 'drama':5 'husband':11 'must':13 'outrac':14 'runaway':2 'student':8 'sumo':16 'unbeliev':4 'wrestler':17
66	BENEATH RUSH	A Astounding Panorama of a Man And a Monkey who must Discover a Man in The First Manned Space Station	2006	1	\N	6	0.99	53	27.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'astound':4 'beneath':1 'discov':14 'first':19 'man':8,16,20 'monkey':11 'must':13 'panorama':5 'rush':2 'space':21 'station':22
67	BERETS AGENT	A Taut Saga of a Crocodile And a Boy who must Overcome a Technical Writer in Ancient China	2006	1	\N	5	2.99	77	24.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'agent':2 'ancient':19 'beret':1 'boy':11 'china':20 'crocodil':8 'must':13 'overcom':14 'saga':5 'taut':4 'technic':16 'writer':17
68	BETRAYED REAR	A Emotional Character Study of a Boat And a Pioneer who must Find a Explorer in A Shark Tank	2006	1	\N	5	4.99	122	26.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'betray':1 'boat':9 'charact':5 'emot':4 'explor':17 'find':15 'must':14 'pioneer':12 'rear':2 'shark':20 'studi':6 'tank':21
69	BEVERLY OUTLAW	A Fanciful Documentary of a Womanizer And a Boat who must Defeat a Madman in The First Manned Space Station	2006	1	\N	3	2.99	85	21.99	R	2006-02-15 05:03:42	{Trailers}	'bever':1 'boat':11 'defeat':14 'documentari':5 'fanci':4 'first':19 'madman':16 'man':20 'must':13 'outlaw':2 'space':21 'station':22 'woman':8
70	BIKINI BORROWERS	A Astounding Drama of a Astronaut And a Cat who must Discover a Woman in The First Manned Space Station	2006	1	\N	7	4.99	142	26.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'astound':4 'astronaut':8 'bikini':1 'borrow':2 'cat':11 'discov':14 'drama':5 'first':19 'man':20 'must':13 'space':21 'station':22 'woman':16
71	BILKO ANONYMOUS	A Emotional Reflection of a Teacher And a Man who must Meet a Cat in The First Manned Space Station	2006	1	\N	3	4.99	100	25.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'anonym':2 'bilko':1 'cat':16 'emot':4 'first':19 'man':11,20 'meet':14 'must':13 'reflect':5 'space':21 'station':22 'teacher':8
72	BILL OTHERS	A Stunning Saga of a Mad Scientist And a Forensic Psychologist who must Challenge a Squirrel in A MySQL Convention	2006	1	\N	6	2.99	93	12.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'bill':1 'challeng':16 'convent':22 'forens':12 'mad':8 'must':15 'mysql':21 'other':2 'psychologist':13 'saga':5 'scientist':9 'squirrel':18 'stun':4
73	BINGO TALENTED	A Touching Tale of a Girl And a Crocodile who must Discover a Waitress in Nigeria	2006	1	\N	5	2.99	150	22.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'bingo':1 'crocodil':11 'discov':14 'girl':8 'must':13 'nigeria':18 'tale':5 'talent':2 'touch':4 'waitress':16
74	BIRCH ANTITRUST	A Fanciful Panorama of a Husband And a Pioneer who must Outgun a Dog in A Baloon	2006	1	\N	4	4.99	162	18.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'antitrust':2 'baloon':19 'birch':1 'dog':16 'fanci':4 'husband':8 'must':13 'outgun':14 'panorama':5 'pioneer':11
75	BIRD INDEPENDENCE	A Thrilling Documentary of a Car And a Student who must Sink a Hunter in The Canadian Rockies	2006	1	\N	6	4.99	163	14.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'bird':1 'canadian':19 'car':8 'documentari':5 'hunter':16 'independ':2 'must':13 'rocki':20 'sink':14 'student':11 'thrill':4
76	BIRDCAGE CASPER	A Fast-Paced Saga of a Frisbee And a Astronaut who must Overcome a Feminist in Ancient India	2006	1	\N	4	0.99	103	23.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'ancient':20 'astronaut':13 'birdcag':1 'casper':2 'fast':5 'fast-pac':4 'feminist':18 'frisbe':10 'india':21 'must':15 'overcom':16 'pace':6 'saga':7
77	BIRDS PERDITION	A Boring Story of a Womanizer And a Pioneer who must Face a Dog in California	2006	1	\N	5	4.99	61	15.99	G	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'bird':1 'bore':4 'california':18 'dog':16 'face':14 'must':13 'perdit':2 'pioneer':11 'stori':5 'woman':8
78	BLACKOUT PRIVATE	A Intrepid Yarn of a Pastry Chef And a Mad Scientist who must Challenge a Secret Agent in Ancient Japan	2006	1	\N	7	2.99	85	12.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'agent':19 'ancient':21 'blackout':1 'challeng':16 'chef':9 'intrepid':4 'japan':22 'mad':12 'must':15 'pastri':8 'privat':2 'scientist':13 'secret':18 'yarn':5
79	BLADE POLISH	A Thoughtful Character Study of a Frisbee And a Pastry Chef who must Fight a Dentist in The First Manned Space Station	2006	1	\N	5	0.99	114	10.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'blade':1 'charact':5 'chef':13 'dentist':18 'fight':16 'first':21 'frisbe':9 'man':22 'must':15 'pastri':12 'polish':2 'space':23 'station':24 'studi':6 'thought':4
80	BLANKET BEVERLY	A Emotional Documentary of a Student And a Girl who must Build a Boat in Nigeria	2006	1	\N	7	2.99	148	21.99	G	2006-02-15 05:03:42	{Trailers}	'bever':2 'blanket':1 'boat':16 'build':14 'documentari':5 'emot':4 'girl':11 'must':13 'nigeria':18 'student':8
81	BLINDNESS GUN	A Touching Drama of a Robot And a Dentist who must Meet a Hunter in A Jet Boat	2006	1	\N	6	4.99	103	29.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'blind':1 'boat':20 'dentist':11 'drama':5 'gun':2 'hunter':16 'jet':19 'meet':14 'must':13 'robot':8 'touch':4
82	BLOOD ARGONAUTS	A Boring Drama of a Explorer And a Man who must Kill a Lumberjack in A Manhattan Penthouse	2006	1	\N	3	0.99	71	13.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'argonaut':2 'blood':1 'bore':4 'drama':5 'explor':8 'kill':14 'lumberjack':16 'man':11 'manhattan':19 'must':13 'penthous':20
83	BLUES INSTINCT	A Insightful Documentary of a Boat And a Composer who must Meet a Forensic Psychologist in An Abandoned Fun House	2006	1	\N	5	2.99	50	18.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'abandon':20 'blue':1 'boat':8 'compos':11 'documentari':5 'forens':16 'fun':21 'hous':22 'insight':4 'instinct':2 'meet':14 'must':13 'psychologist':17
84	BOILED DARES	A Awe-Inspiring Story of a Waitress And a Dog who must Discover a Dentist in Ancient Japan	2006	1	\N	7	4.99	102	13.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'ancient':20 'awe':5 'awe-inspir':4 'boil':1 'dare':2 'dentist':18 'discov':16 'dog':13 'inspir':6 'japan':21 'must':15 'stori':7 'waitress':10
85	BONNIE HOLOCAUST	A Fast-Paced Story of a Crocodile And a Robot who must Find a Moose in Ancient Japan	2006	1	\N	4	0.99	63	29.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'ancient':20 'bonni':1 'crocodil':10 'fast':5 'fast-pac':4 'find':16 'holocaust':2 'japan':21 'moos':18 'must':15 'pace':6 'robot':13 'stori':7
86	BOOGIE AMELIE	A Lacklusture Character Study of a Husband And a Sumo Wrestler who must Succumb a Technical Writer in The Gulf of Mexico	2006	1	\N	6	4.99	121	11.99	R	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'ameli':2 'boogi':1 'charact':5 'gulf':22 'husband':9 'lacklustur':4 'mexico':24 'must':15 'studi':6 'succumb':16 'sumo':12 'technic':18 'wrestler':13 'writer':19
87	BOONDOCK BALLROOM	A Fateful Panorama of a Crocodile And a Boy who must Defeat a Monkey in The Gulf of Mexico	2006	1	\N	7	0.99	76	14.99	NC-17	2006-02-15 05:03:42	{"Behind the Scenes"}	'ballroom':2 'boondock':1 'boy':11 'crocodil':8 'defeat':14 'fate':4 'gulf':19 'mexico':21 'monkey':16 'must':13 'panorama':5
88	BORN SPINAL	A Touching Epistle of a Frisbee And a Husband who must Pursue a Student in Nigeria	2006	1	\N	7	4.99	179	17.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'born':1 'epistl':5 'frisbe':8 'husband':11 'must':13 'nigeria':18 'pursu':14 'spinal':2 'student':16 'touch':4
89	BORROWERS BEDAZZLED	A Brilliant Epistle of a Teacher And a Sumo Wrestler who must Defeat a Man in An Abandoned Fun House	2006	1	\N	7	0.99	63	22.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':20 'bedazzl':2 'borrow':1 'brilliant':4 'defeat':15 'epistl':5 'fun':21 'hous':22 'man':17 'must':14 'sumo':11 'teacher':8 'wrestler':12
90	BOULEVARD MOB	A Fateful Epistle of a Moose And a Monkey who must Confront a Lumberjack in Ancient China	2006	1	\N	3	0.99	63	11.99	R	2006-02-15 05:03:42	{Trailers}	'ancient':18 'boulevard':1 'china':19 'confront':14 'epistl':5 'fate':4 'lumberjack':16 'mob':2 'monkey':11 'moos':8 'must':13
182	CONTROL ANTHEM	A Fateful Documentary of a Robot And a Student who must Battle a Cat in A Monastery	2006	1	\N	7	4.99	185	9.99	G	2006-02-15 05:03:42	{Commentaries}	'anthem':2 'battl':14 'cat':16 'control':1 'documentari':5 'fate':4 'monasteri':19 'must':13 'robot':8 'student':11
91	BOUND CHEAPER	A Thrilling Panorama of a Database Administrator And a Astronaut who must Challenge a Lumberjack in A Baloon	2006	1	\N	5	0.99	98	17.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'administr':9 'astronaut':12 'baloon':20 'bound':1 'challeng':15 'cheaper':2 'databas':8 'lumberjack':17 'must':14 'panorama':5 'thrill':4
92	BOWFINGER GABLES	A Fast-Paced Yarn of a Waitress And a Composer who must Outgun a Dentist in California	2006	1	\N	7	4.99	72	19.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'bowfing':1 'california':20 'compos':13 'dentist':18 'fast':5 'fast-pac':4 'gabl':2 'must':15 'outgun':16 'pace':6 'waitress':10 'yarn':7
93	BRANNIGAN SUNRISE	A Amazing Epistle of a Moose And a Crocodile who must Outrace a Dog in Berlin	2006	1	\N	4	4.99	121	27.99	PG	2006-02-15 05:03:42	{Trailers}	'amaz':4 'berlin':18 'brannigan':1 'crocodil':11 'dog':16 'epistl':5 'moos':8 'must':13 'outrac':14 'sunris':2
94	BRAVEHEART HUMAN	A Insightful Story of a Dog And a Pastry Chef who must Battle a Girl in Berlin	2006	1	\N	7	2.99	176	14.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'battl':15 'berlin':19 'braveheart':1 'chef':12 'dog':8 'girl':17 'human':2 'insight':4 'must':14 'pastri':11 'stori':5
95	BREAKFAST GOLDFINGER	A Beautiful Reflection of a Student And a Student who must Fight a Moose in Berlin	2006	1	\N	5	4.99	123	18.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'beauti':4 'berlin':18 'breakfast':1 'fight':14 'goldfing':2 'moos':16 'must':13 'reflect':5 'student':8,11
96	BREAKING HOME	A Beautiful Display of a Secret Agent And a Monkey who must Battle a Sumo Wrestler in An Abandoned Mine Shaft	2006	1	\N	4	2.99	169	21.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'abandon':21 'agent':9 'battl':15 'beauti':4 'break':1 'display':5 'home':2 'mine':22 'monkey':12 'must':14 'secret':8 'shaft':23 'sumo':17 'wrestler':18
97	BRIDE INTRIGUE	A Epic Tale of a Robot And a Monkey who must Vanquish a Man in New Orleans	2006	1	\N	7	0.99	56	24.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'bride':1 'epic':4 'intrigu':2 'man':16 'monkey':11 'must':13 'new':18 'orlean':19 'robot':8 'tale':5 'vanquish':14
98	BRIGHT ENCOUNTERS	A Fateful Yarn of a Lumberjack And a Feminist who must Conquer a Student in A Jet Boat	2006	1	\N	4	4.99	73	12.99	PG-13	2006-02-15 05:03:42	{Trailers}	'boat':20 'bright':1 'conquer':14 'encount':2 'fate':4 'feminist':11 'jet':19 'lumberjack':8 'must':13 'student':16 'yarn':5
99	BRINGING HYSTERICAL	A Fateful Saga of a A Shark And a Technical Writer who must Find a Woman in A Jet Boat	2006	1	\N	7	2.99	136	14.99	PG	2006-02-15 05:03:42	{Trailers}	'boat':22 'bring':1 'fate':4 'find':16 'hyster':2 'jet':21 'must':15 'saga':5 'shark':9 'technic':12 'woman':18 'writer':13
100	BROOKLYN DESERT	A Beautiful Drama of a Dentist And a Composer who must Battle a Sumo Wrestler in The First Manned Space Station	2006	1	\N	7	4.99	161	21.99	R	2006-02-15 05:03:42	{Commentaries}	'battl':14 'beauti':4 'brooklyn':1 'compos':11 'dentist':8 'desert':2 'drama':5 'first':20 'man':21 'must':13 'space':22 'station':23 'sumo':16 'wrestler':17
101	BROTHERHOOD BLANKET	A Fateful Character Study of a Butler And a Technical Writer who must Sink a Astronaut in Ancient Japan	2006	1	\N	3	0.99	73	26.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'ancient':20 'astronaut':18 'blanket':2 'brotherhood':1 'butler':9 'charact':5 'fate':4 'japan':21 'must':15 'sink':16 'studi':6 'technic':12 'writer':13
102	BUBBLE GROSSE	A Awe-Inspiring Panorama of a Crocodile And a Moose who must Confront a Girl in A Baloon	2006	1	\N	4	4.99	60	20.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'awe':5 'awe-inspir':4 'baloon':21 'bubbl':1 'confront':16 'crocodil':10 'girl':18 'gross':2 'inspir':6 'moos':13 'must':15 'panorama':7
103	BUCKET BROTHERHOOD	A Amazing Display of a Girl And a Womanizer who must Succumb a Lumberjack in A Baloon Factory	2006	1	\N	7	4.99	133	27.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'amaz':4 'baloon':19 'brotherhood':2 'bucket':1 'display':5 'factori':20 'girl':8 'lumberjack':16 'must':13 'succumb':14 'woman':11
104	BUGSY SONG	A Awe-Inspiring Character Study of a Secret Agent And a Boat who must Find a Squirrel in The First Manned Space Station	2006	1	\N	4	2.99	119	17.99	G	2006-02-15 05:03:42	{Commentaries}	'agent':12 'awe':5 'awe-inspir':4 'boat':15 'bugsi':1 'charact':7 'find':18 'first':23 'inspir':6 'man':24 'must':17 'secret':11 'song':2 'space':25 'squirrel':20 'station':26 'studi':8
105	BULL SHAWSHANK	A Fanciful Drama of a Moose And a Squirrel who must Conquer a Pioneer in The Canadian Rockies	2006	1	\N	6	0.99	125	21.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes"}	'bull':1 'canadian':19 'conquer':14 'drama':5 'fanci':4 'moos':8 'must':13 'pioneer':16 'rocki':20 'shawshank':2 'squirrel':11
106	BULWORTH COMMANDMENTS	A Amazing Display of a Mad Cow And a Pioneer who must Redeem a Sumo Wrestler in The Outback	2006	1	\N	4	2.99	61	14.99	G	2006-02-15 05:03:42	{Trailers}	'amaz':4 'bulworth':1 'command':2 'cow':9 'display':5 'mad':8 'must':14 'outback':21 'pioneer':12 'redeem':15 'sumo':17 'wrestler':18
107	BUNCH MINDS	A Emotional Story of a Feminist And a Feminist who must Escape a Pastry Chef in A MySQL Convention	2006	1	\N	4	2.99	63	13.99	G	2006-02-15 05:03:42	{"Behind the Scenes"}	'bunch':1 'chef':17 'convent':21 'emot':4 'escap':14 'feminist':8,11 'mind':2 'must':13 'mysql':20 'pastri':16 'stori':5
108	BUTCH PANTHER	A Lacklusture Yarn of a Feminist And a Database Administrator who must Face a Hunter in New Orleans	2006	1	\N	6	0.99	67	19.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'administr':12 'butch':1 'databas':11 'face':15 'feminist':8 'hunter':17 'lacklustur':4 'must':14 'new':19 'orlean':20 'panther':2 'yarn':5
109	BUTTERFLY CHOCOLAT	A Fateful Story of a Girl And a Composer who must Conquer a Husband in A Shark Tank	2006	1	\N	3	0.99	89	17.99	G	2006-02-15 05:03:42	{"Behind the Scenes"}	'butterfli':1 'chocolat':2 'compos':11 'conquer':14 'fate':4 'girl':8 'husband':16 'must':13 'shark':19 'stori':5 'tank':20
110	CABIN FLASH	A Stunning Epistle of a Boat And a Man who must Challenge a A Shark in A Baloon Factory	2006	1	\N	4	0.99	53	25.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'baloon':20 'boat':8 'cabin':1 'challeng':14 'epistl':5 'factori':21 'flash':2 'man':11 'must':13 'shark':17 'stun':4
111	CADDYSHACK JEDI	A Awe-Inspiring Epistle of a Woman And a Madman who must Fight a Robot in Soviet Georgia	2006	1	\N	3	0.99	52	17.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'awe':5 'awe-inspir':4 'caddyshack':1 'epistl':7 'fight':16 'georgia':21 'inspir':6 'jedi':2 'madman':13 'must':15 'robot':18 'soviet':20 'woman':10
112	CALENDAR GUNFIGHT	A Thrilling Drama of a Frisbee And a Lumberjack who must Sink a Man in Nigeria	2006	1	\N	4	4.99	120	22.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'calendar':1 'drama':5 'frisbe':8 'gunfight':2 'lumberjack':11 'man':16 'must':13 'nigeria':18 'sink':14 'thrill':4
113	CALIFORNIA BIRDS	A Thrilling Yarn of a Database Administrator And a Robot who must Battle a Database Administrator in Ancient India	2006	1	\N	4	4.99	75	19.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'administr':9,18 'ancient':20 'battl':15 'bird':2 'california':1 'databas':8,17 'india':21 'must':14 'robot':12 'thrill':4 'yarn':5
114	CAMELOT VACATION	A Touching Character Study of a Woman And a Waitress who must Battle a Pastry Chef in A MySQL Convention	2006	1	\N	3	0.99	61	26.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'battl':15 'camelot':1 'charact':5 'chef':18 'convent':22 'must':14 'mysql':21 'pastri':17 'studi':6 'touch':4 'vacat':2 'waitress':12 'woman':9
115	CAMPUS REMEMBER	A Astounding Drama of a Crocodile And a Mad Cow who must Build a Robot in A Jet Boat	2006	1	\N	5	2.99	167	27.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'astound':4 'boat':21 'build':15 'campus':1 'cow':12 'crocodil':8 'drama':5 'jet':20 'mad':11 'must':14 'rememb':2 'robot':17
116	CANDIDATE PERDITION	A Brilliant Epistle of a Composer And a Database Administrator who must Vanquish a Mad Scientist in The First Manned Space Station	2006	1	\N	4	2.99	70	10.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'administr':12 'brilliant':4 'candid':1 'compos':8 'databas':11 'epistl':5 'first':21 'mad':17 'man':22 'must':14 'perdit':2 'scientist':18 'space':23 'station':24 'vanquish':15
117	CANDLES GRAPES	A Fanciful Character Study of a Monkey And a Explorer who must Build a Astronaut in An Abandoned Fun House	2006	1	\N	6	4.99	135	15.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'abandon':20 'astronaut':17 'build':15 'candl':1 'charact':5 'explor':12 'fanci':4 'fun':21 'grape':2 'hous':22 'monkey':9 'must':14 'studi':6
118	CANYON STOCK	A Thoughtful Reflection of a Waitress And a Feminist who must Escape a Squirrel in A Manhattan Penthouse	2006	1	\N	7	0.99	85	26.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'canyon':1 'escap':14 'feminist':11 'manhattan':19 'must':13 'penthous':20 'reflect':5 'squirrel':16 'stock':2 'thought':4 'waitress':8
119	CAPER MOTIONS	A Fateful Saga of a Moose And a Car who must Pursue a Woman in A MySQL Convention	2006	1	\N	6	0.99	176	22.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'caper':1 'car':11 'convent':20 'fate':4 'moos':8 'motion':2 'must':13 'mysql':19 'pursu':14 'saga':5 'woman':16
120	CARIBBEAN LIBERTY	A Fanciful Tale of a Pioneer And a Technical Writer who must Outgun a Pioneer in A Shark Tank	2006	1	\N	3	4.99	92	16.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'caribbean':1 'fanci':4 'liberti':2 'must':14 'outgun':15 'pioneer':8,17 'shark':20 'tale':5 'tank':21 'technic':11 'writer':12
121	CAROL TEXAS	A Astounding Character Study of a Composer And a Student who must Overcome a Composer in A Monastery	2006	1	\N	4	2.99	151	15.99	PG	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'astound':4 'carol':1 'charact':5 'compos':9,17 'monasteri':20 'must':14 'overcom':15 'student':12 'studi':6 'texa':2
122	CARRIE BUNCH	A Amazing Epistle of a Student And a Astronaut who must Discover a Frisbee in The Canadian Rockies	2006	1	\N	7	0.99	114	11.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'amaz':4 'astronaut':11 'bunch':2 'canadian':19 'carri':1 'discov':14 'epistl':5 'frisbe':16 'must':13 'rocki':20 'student':8
123	CASABLANCA SUPER	A Amazing Panorama of a Crocodile And a Forensic Psychologist who must Pursue a Secret Agent in The First Manned Space Station	2006	1	\N	6	4.99	85	22.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'agent':18 'amaz':4 'casablanca':1 'crocodil':8 'first':21 'forens':11 'man':22 'must':14 'panorama':5 'psychologist':12 'pursu':15 'secret':17 'space':23 'station':24 'super':2
124	CASPER DRAGONFLY	A Intrepid Documentary of a Boat And a Crocodile who must Chase a Robot in The Sahara Desert	2006	1	\N	3	4.99	163	16.99	PG-13	2006-02-15 05:03:42	{Trailers}	'boat':8 'casper':1 'chase':14 'crocodil':11 'desert':20 'documentari':5 'dragonfli':2 'intrepid':4 'must':13 'robot':16 'sahara':19
125	CASSIDY WYOMING	A Intrepid Drama of a Frisbee And a Hunter who must Kill a Secret Agent in New Orleans	2006	1	\N	5	2.99	61	19.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'agent':17 'cassidi':1 'drama':5 'frisbe':8 'hunter':11 'intrepid':4 'kill':14 'must':13 'new':19 'orlean':20 'secret':16 'wyom':2
126	CASUALTIES ENCINO	A Insightful Yarn of a A Shark And a Pastry Chef who must Face a Boy in A Monastery	2006	1	\N	3	4.99	179	16.99	G	2006-02-15 05:03:42	{Trailers}	'boy':18 'casualti':1 'chef':13 'encino':2 'face':16 'insight':4 'monasteri':21 'must':15 'pastri':12 'shark':9 'yarn':5
127	CAT CONEHEADS	A Fast-Paced Panorama of a Girl And a A Shark who must Confront a Boy in Ancient India	2006	1	\N	5	4.99	112	14.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'ancient':21 'boy':19 'cat':1 'conehead':2 'confront':17 'fast':5 'fast-pac':4 'girl':10 'india':22 'must':16 'pace':6 'panorama':7 'shark':14
128	CATCH AMISTAD	A Boring Reflection of a Lumberjack And a Feminist who must Discover a Woman in Nigeria	2006	1	\N	7	0.99	183	10.99	G	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'amistad':2 'bore':4 'catch':1 'discov':14 'feminist':11 'lumberjack':8 'must':13 'nigeria':18 'reflect':5 'woman':16
129	CAUSE DATE	A Taut Tale of a Explorer And a Pastry Chef who must Conquer a Hunter in A MySQL Convention	2006	1	\N	3	2.99	179	16.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'caus':1 'chef':12 'conquer':15 'convent':21 'date':2 'explor':8 'hunter':17 'must':14 'mysql':20 'pastri':11 'tale':5 'taut':4
130	CELEBRITY HORN	A Amazing Documentary of a Secret Agent And a Astronaut who must Vanquish a Hunter in A Shark Tank	2006	1	\N	7	0.99	110	24.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'agent':9 'amaz':4 'astronaut':12 'celebr':1 'documentari':5 'horn':2 'hunter':17 'must':14 'secret':8 'shark':20 'tank':21 'vanquish':15
131	CENTER DINOSAUR	A Beautiful Character Study of a Sumo Wrestler And a Dentist who must Find a Dog in California	2006	1	\N	5	4.99	152	12.99	PG	2006-02-15 05:03:42	{"Deleted Scenes"}	'beauti':4 'california':20 'center':1 'charact':5 'dentist':13 'dinosaur':2 'dog':18 'find':16 'must':15 'studi':6 'sumo':9 'wrestler':10
132	CHAINSAW UPTOWN	A Beautiful Documentary of a Boy And a Robot who must Discover a Squirrel in Australia	2006	1	\N	6	0.99	114	25.99	PG	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'australia':18 'beauti':4 'boy':8 'chainsaw':1 'discov':14 'documentari':5 'must':13 'robot':11 'squirrel':16 'uptown':2
133	CHAMBER ITALIAN	A Fateful Reflection of a Moose And a Husband who must Overcome a Monkey in Nigeria	2006	1	\N	7	4.99	117	14.99	NC-17	2006-02-15 05:03:42	{Trailers}	'chamber':1 'fate':4 'husband':11 'italian':2 'monkey':16 'moos':8 'must':13 'nigeria':18 'overcom':14 'reflect':5
134	CHAMPION FLATLINERS	A Amazing Story of a Mad Cow And a Dog who must Kill a Husband in A Monastery	2006	1	\N	4	4.99	51	21.99	PG	2006-02-15 05:03:42	{Trailers}	'amaz':4 'champion':1 'cow':9 'dog':12 'flatlin':2 'husband':17 'kill':15 'mad':8 'monasteri':20 'must':14 'stori':5
135	CHANCE RESURRECTION	A Astounding Story of a Forensic Psychologist And a Forensic Psychologist who must Overcome a Moose in Ancient China	2006	1	\N	3	2.99	70	22.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'ancient':20 'astound':4 'chanc':1 'china':21 'forens':8,12 'moos':18 'must':15 'overcom':16 'psychologist':9,13 'resurrect':2 'stori':5
136	CHAPLIN LICENSE	A Boring Drama of a Dog And a Forensic Psychologist who must Outrace a Explorer in Ancient India	2006	1	\N	7	2.99	146	26.99	NC-17	2006-02-15 05:03:42	{"Behind the Scenes"}	'ancient':19 'bore':4 'chaplin':1 'dog':8 'drama':5 'explor':17 'forens':11 'india':20 'licens':2 'must':14 'outrac':15 'psychologist':12
137	CHARADE DUFFEL	A Action-Packed Display of a Man And a Waitress who must Build a Dog in A MySQL Convention	2006	1	\N	3	2.99	66	21.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'action':5 'action-pack':4 'build':16 'charad':1 'convent':22 'display':7 'dog':18 'duffel':2 'man':10 'must':15 'mysql':21 'pack':6 'waitress':13
138	CHARIOTS CONSPIRACY	A Unbelieveable Epistle of a Robot And a Husband who must Chase a Robot in The First Manned Space Station	2006	1	\N	5	2.99	71	29.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'chariot':1 'chase':14 'conspiraci':2 'epistl':5 'first':19 'husband':11 'man':20 'must':13 'robot':8,16 'space':21 'station':22 'unbeliev':4
139	CHASING FIGHT	A Astounding Saga of a Technical Writer And a Butler who must Battle a Butler in A Shark Tank	2006	1	\N	7	4.99	114	21.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'astound':4 'battl':15 'butler':12,17 'chase':1 'fight':2 'must':14 'saga':5 'shark':20 'tank':21 'technic':8 'writer':9
140	CHEAPER CLYDE	A Emotional Character Study of a Pioneer And a Girl who must Discover a Dog in Ancient Japan	2006	1	\N	6	0.99	87	23.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'ancient':19 'charact':5 'cheaper':1 'clyde':2 'discov':15 'dog':17 'emot':4 'girl':12 'japan':20 'must':14 'pioneer':9 'studi':6
141	CHICAGO NORTH	A Fateful Yarn of a Mad Cow And a Waitress who must Battle a Student in California	2006	1	\N	6	4.99	185	11.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'battl':15 'california':19 'chicago':1 'cow':9 'fate':4 'mad':8 'must':14 'north':2 'student':17 'waitress':12 'yarn':5
142	CHICKEN HELLFIGHTERS	A Emotional Drama of a Dog And a Explorer who must Outrace a Technical Writer in Australia	2006	1	\N	3	0.99	122	24.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'australia':19 'chicken':1 'dog':8 'drama':5 'emot':4 'explor':11 'hellfight':2 'must':13 'outrac':14 'technic':16 'writer':17
143	CHILL LUCK	A Lacklusture Epistle of a Boat And a Technical Writer who must Fight a A Shark in The Canadian Rockies	2006	1	\N	6	0.99	142	17.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'boat':8 'canadian':21 'chill':1 'epistl':5 'fight':15 'lacklustur':4 'luck':2 'must':14 'rocki':22 'shark':18 'technic':11 'writer':12
144	CHINATOWN GLADIATOR	A Brilliant Panorama of a Technical Writer And a Lumberjack who must Escape a Butler in Ancient India	2006	1	\N	7	4.99	61	24.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'ancient':19 'brilliant':4 'butler':17 'chinatown':1 'escap':15 'gladiat':2 'india':20 'lumberjack':12 'must':14 'panorama':5 'technic':8 'writer':9
145	CHISUM BEHAVIOR	A Epic Documentary of a Sumo Wrestler And a Butler who must Kill a Car in Ancient India	2006	1	\N	5	4.99	124	25.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'ancient':19 'behavior':2 'butler':12 'car':17 'chisum':1 'documentari':5 'epic':4 'india':20 'kill':15 'must':14 'sumo':8 'wrestler':9
146	CHITTY LOCK	A Boring Epistle of a Boat And a Database Administrator who must Kill a Sumo Wrestler in The First Manned Space Station	2006	1	\N	6	2.99	107	24.99	G	2006-02-15 05:03:42	{Commentaries}	'administr':12 'boat':8 'bore':4 'chitti':1 'databas':11 'epistl':5 'first':21 'kill':15 'lock':2 'man':22 'must':14 'space':23 'station':24 'sumo':17 'wrestler':18
147	CHOCOLAT HARRY	A Action-Packed Epistle of a Dentist And a Moose who must Meet a Mad Cow in Ancient Japan	2006	1	\N	5	0.99	101	16.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'action':5 'action-pack':4 'ancient':21 'chocolat':1 'cow':19 'dentist':10 'epistl':7 'harri':2 'japan':22 'mad':18 'meet':16 'moos':13 'must':15 'pack':6
148	CHOCOLATE DUCK	A Unbelieveable Story of a Mad Scientist And a Technical Writer who must Discover a Composer in Ancient China	2006	1	\N	3	2.99	132	13.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'ancient':20 'china':21 'chocol':1 'compos':18 'discov':16 'duck':2 'mad':8 'must':15 'scientist':9 'stori':5 'technic':12 'unbeliev':4 'writer':13
149	CHRISTMAS MOONSHINE	A Action-Packed Epistle of a Feminist And a Astronaut who must Conquer a Boat in A Manhattan Penthouse	2006	1	\N	7	0.99	150	21.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'action':5 'action-pack':4 'astronaut':13 'boat':18 'christma':1 'conquer':16 'epistl':7 'feminist':10 'manhattan':21 'moonshin':2 'must':15 'pack':6 'penthous':22
150	CIDER DESIRE	A Stunning Character Study of a Composer And a Mad Cow who must Succumb a Cat in Soviet Georgia	2006	1	\N	7	2.99	101	9.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'cat':18 'charact':5 'cider':1 'compos':9 'cow':13 'desir':2 'georgia':21 'mad':12 'must':15 'soviet':20 'studi':6 'stun':4 'succumb':16
151	CINCINATTI WHISPERER	A Brilliant Saga of a Pastry Chef And a Hunter who must Confront a Butler in Berlin	2006	1	\N	5	4.99	143	26.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes"}	'berlin':19 'brilliant':4 'butler':17 'chef':9 'cincinatti':1 'confront':15 'hunter':12 'must':14 'pastri':8 'saga':5 'whisper':2
152	CIRCUS YOUTH	A Thoughtful Drama of a Pastry Chef And a Dentist who must Pursue a Girl in A Baloon	2006	1	\N	5	2.99	90	13.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'baloon':20 'chef':9 'circus':1 'dentist':12 'drama':5 'girl':17 'must':14 'pastri':8 'pursu':15 'thought':4 'youth':2
153	CITIZEN SHREK	A Fanciful Character Study of a Technical Writer And a Husband who must Redeem a Robot in The Outback	2006	1	\N	7	0.99	165	18.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'charact':5 'citizen':1 'fanci':4 'husband':13 'must':15 'outback':21 'redeem':16 'robot':18 'shrek':2 'studi':6 'technic':9 'writer':10
154	CLASH FREDDY	A Amazing Yarn of a Composer And a Squirrel who must Escape a Astronaut in Australia	2006	1	\N	6	2.99	81	12.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'amaz':4 'astronaut':16 'australia':18 'clash':1 'compos':8 'escap':14 'freddi':2 'must':13 'squirrel':11 'yarn':5
155	CLEOPATRA DEVIL	A Fanciful Documentary of a Crocodile And a Technical Writer who must Fight a A Shark in A Baloon	2006	1	\N	6	0.99	150	26.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'baloon':21 'cleopatra':1 'crocodil':8 'devil':2 'documentari':5 'fanci':4 'fight':15 'must':14 'shark':18 'technic':11 'writer':12
156	CLERKS ANGELS	A Thrilling Display of a Sumo Wrestler And a Girl who must Confront a Man in A Baloon	2006	1	\N	3	4.99	164	15.99	G	2006-02-15 05:03:42	{Commentaries}	'angel':2 'baloon':20 'clerk':1 'confront':15 'display':5 'girl':12 'man':17 'must':14 'sumo':8 'thrill':4 'wrestler':9
157	CLOCKWORK PARADISE	A Insightful Documentary of a Technical Writer And a Feminist who must Challenge a Cat in A Baloon	2006	1	\N	7	0.99	143	29.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'baloon':20 'cat':17 'challeng':15 'clockwork':1 'documentari':5 'feminist':12 'insight':4 'must':14 'paradis':2 'technic':8 'writer':9
158	CLONES PINOCCHIO	A Amazing Drama of a Car And a Robot who must Pursue a Dentist in New Orleans	2006	1	\N	6	2.99	124	16.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'amaz':4 'car':8 'clone':1 'dentist':16 'drama':5 'must':13 'new':18 'orlean':19 'pinocchio':2 'pursu':14 'robot':11
159	CLOSER BANG	A Unbelieveable Panorama of a Frisbee And a Hunter who must Vanquish a Monkey in Ancient India	2006	1	\N	5	4.99	58	12.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'ancient':18 'bang':2 'closer':1 'frisbe':8 'hunter':11 'india':19 'monkey':16 'must':13 'panorama':5 'unbeliev':4 'vanquish':14
160	CLUB GRAFFITI	A Epic Tale of a Pioneer And a Hunter who must Escape a Girl in A U-Boat	2006	1	\N	4	0.99	65	12.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'boat':21 'club':1 'epic':4 'escap':14 'girl':16 'graffiti':2 'hunter':11 'must':13 'pioneer':8 'tale':5 'u':20 'u-boat':19
161	CLUE GRAIL	A Taut Tale of a Butler And a Mad Scientist who must Build a Crocodile in Ancient China	2006	1	\N	6	4.99	70	27.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'ancient':19 'build':15 'butler':8 'china':20 'clue':1 'crocodil':17 'grail':2 'mad':11 'must':14 'scientist':12 'tale':5 'taut':4
162	CLUELESS BUCKET	A Taut Tale of a Car And a Pioneer who must Conquer a Sumo Wrestler in An Abandoned Fun House	2006	1	\N	4	2.99	95	13.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'abandon':20 'bucket':2 'car':8 'clueless':1 'conquer':14 'fun':21 'hous':22 'must':13 'pioneer':11 'sumo':16 'tale':5 'taut':4 'wrestler':17
163	CLYDE THEORY	A Beautiful Yarn of a Astronaut And a Frisbee who must Overcome a Explorer in A Jet Boat	2006	1	\N	4	0.99	139	29.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'astronaut':8 'beauti':4 'boat':20 'clyde':1 'explor':16 'frisbe':11 'jet':19 'must':13 'overcom':14 'theori':2 'yarn':5
164	COAST RAINBOW	A Astounding Documentary of a Mad Cow And a Pioneer who must Challenge a Butler in The Sahara Desert	2006	1	\N	4	0.99	55	20.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'astound':4 'butler':17 'challeng':15 'coast':1 'cow':9 'desert':21 'documentari':5 'mad':8 'must':14 'pioneer':12 'rainbow':2 'sahara':20
165	COLDBLOODED DARLING	A Brilliant Panorama of a Dentist And a Moose who must Find a Student in The Gulf of Mexico	2006	1	\N	7	4.99	70	27.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'brilliant':4 'coldblood':1 'darl':2 'dentist':8 'find':14 'gulf':19 'mexico':21 'moos':11 'must':13 'panorama':5 'student':16
166	COLOR PHILADELPHIA	A Thoughtful Panorama of a Car And a Crocodile who must Sink a Monkey in The Sahara Desert	2006	1	\N	6	2.99	149	19.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'car':8 'color':1 'crocodil':11 'desert':20 'monkey':16 'must':13 'panorama':5 'philadelphia':2 'sahara':19 'sink':14 'thought':4
167	COMA HEAD	A Awe-Inspiring Drama of a Boy And a Frisbee who must Escape a Pastry Chef in California	2006	1	\N	6	4.99	109	10.99	NC-17	2006-02-15 05:03:42	{Commentaries}	'awe':5 'awe-inspir':4 'boy':10 'california':21 'chef':19 'coma':1 'drama':7 'escap':16 'frisbe':13 'head':2 'inspir':6 'must':15 'pastri':18
168	COMANCHEROS ENEMY	A Boring Saga of a Lumberjack And a Monkey who must Find a Monkey in The Gulf of Mexico	2006	1	\N	5	0.99	67	23.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'bore':4 'comanchero':1 'enemi':2 'find':14 'gulf':19 'lumberjack':8 'mexico':21 'monkey':11,16 'must':13 'saga':5
169	COMFORTS RUSH	A Unbelieveable Panorama of a Pioneer And a Husband who must Meet a Mad Cow in An Abandoned Mine Shaft	2006	1	\N	3	2.99	76	19.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'abandon':20 'comfort':1 'cow':17 'husband':11 'mad':16 'meet':14 'mine':21 'must':13 'panorama':5 'pioneer':8 'rush':2 'shaft':22 'unbeliev':4
170	COMMAND DARLING	A Awe-Inspiring Tale of a Forensic Psychologist And a Woman who must Challenge a Database Administrator in Ancient Japan	2006	1	\N	5	4.99	120	28.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'administr':20 'ancient':22 'awe':5 'awe-inspir':4 'challeng':17 'command':1 'darl':2 'databas':19 'forens':10 'inspir':6 'japan':23 'must':16 'psychologist':11 'tale':7 'woman':14
171	COMMANDMENTS EXPRESS	A Fanciful Saga of a Student And a Mad Scientist who must Battle a Hunter in An Abandoned Mine Shaft	2006	1	\N	6	4.99	59	13.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'abandon':20 'battl':15 'command':1 'express':2 'fanci':4 'hunter':17 'mad':11 'mine':21 'must':14 'saga':5 'scientist':12 'shaft':22 'student':8
172	CONEHEADS SMOOCHY	A Touching Story of a Womanizer And a Composer who must Pursue a Husband in Nigeria	2006	1	\N	7	4.99	112	12.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'compos':11 'conehead':1 'husband':16 'must':13 'nigeria':18 'pursu':14 'smoochi':2 'stori':5 'touch':4 'woman':8
173	CONFESSIONS MAGUIRE	A Insightful Story of a Car And a Boy who must Battle a Technical Writer in A Baloon	2006	1	\N	7	4.99	65	25.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'baloon':20 'battl':14 'boy':11 'car':8 'confess':1 'insight':4 'maguir':2 'must':13 'stori':5 'technic':16 'writer':17
174	CONFIDENTIAL INTERVIEW	A Stunning Reflection of a Cat And a Woman who must Find a Astronaut in Ancient Japan	2006	1	\N	6	4.99	180	13.99	NC-17	2006-02-15 05:03:42	{Commentaries}	'ancient':18 'astronaut':16 'cat':8 'confidenti':1 'find':14 'interview':2 'japan':19 'must':13 'reflect':5 'stun':4 'woman':11
175	CONFUSED CANDLES	A Stunning Epistle of a Cat And a Forensic Psychologist who must Confront a Pioneer in A Baloon	2006	1	\N	3	2.99	122	27.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'baloon':20 'candl':2 'cat':8 'confront':15 'confus':1 'epistl':5 'forens':11 'must':14 'pioneer':17 'psychologist':12 'stun':4
176	CONGENIALITY QUEST	A Touching Documentary of a Cat And a Pastry Chef who must Find a Lumberjack in A Baloon	2006	1	\N	6	0.99	87	21.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'baloon':20 'cat':8 'chef':12 'congeni':1 'documentari':5 'find':15 'lumberjack':17 'must':14 'pastri':11 'quest':2 'touch':4
177	CONNECTICUT TRAMP	A Unbelieveable Drama of a Crocodile And a Mad Cow who must Reach a Dentist in A Shark Tank	2006	1	\N	4	4.99	172	20.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'connecticut':1 'cow':12 'crocodil':8 'dentist':17 'drama':5 'mad':11 'must':14 'reach':15 'shark':20 'tank':21 'tramp':2 'unbeliev':4
178	CONNECTION MICROCOSMOS	A Fateful Documentary of a Crocodile And a Husband who must Face a Husband in The First Manned Space Station	2006	1	\N	6	0.99	115	25.99	G	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'connect':1 'crocodil':8 'documentari':5 'face':14 'fate':4 'first':19 'husband':11,16 'man':20 'microcosmo':2 'must':13 'space':21 'station':22
179	CONQUERER NUTS	A Taut Drama of a Mad Scientist And a Man who must Escape a Pioneer in An Abandoned Mine Shaft	2006	1	\N	4	4.99	173	14.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':20 'conquer':1 'drama':5 'escap':15 'mad':8 'man':12 'mine':21 'must':14 'nut':2 'pioneer':17 'scientist':9 'shaft':22 'taut':4
180	CONSPIRACY SPIRIT	A Awe-Inspiring Story of a Student And a Frisbee who must Conquer a Crocodile in An Abandoned Mine Shaft	2006	1	\N	4	2.99	184	27.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'abandon':21 'awe':5 'awe-inspir':4 'conquer':16 'conspiraci':1 'crocodil':18 'frisbe':13 'inspir':6 'mine':22 'must':15 'shaft':23 'spirit':2 'stori':7 'student':10
181	CONTACT ANONYMOUS	A Insightful Display of a A Shark And a Monkey who must Face a Database Administrator in Ancient India	2006	1	\N	7	2.99	166	10.99	PG-13	2006-02-15 05:03:42	{Commentaries}	'administr':18 'ancient':20 'anonym':2 'contact':1 'databas':17 'display':5 'face':15 'india':21 'insight':4 'monkey':12 'must':14 'shark':9
183	CONVERSATION DOWNHILL	A Taut Character Study of a Husband And a Waitress who must Sink a Squirrel in A MySQL Convention	2006	1	\N	4	4.99	112	14.99	R	2006-02-15 05:03:42	{Commentaries}	'charact':5 'convent':21 'convers':1 'downhil':2 'husband':9 'must':14 'mysql':20 'sink':15 'squirrel':17 'studi':6 'taut':4 'waitress':12
184	CORE SUIT	A Unbelieveable Tale of a Car And a Explorer who must Confront a Boat in A Manhattan Penthouse	2006	1	\N	3	2.99	92	24.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'boat':16 'car':8 'confront':14 'core':1 'explor':11 'manhattan':19 'must':13 'penthous':20 'suit':2 'tale':5 'unbeliev':4
185	COWBOY DOOM	A Astounding Drama of a Boy And a Lumberjack who must Fight a Butler in A Baloon	2006	1	\N	3	2.99	146	10.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'astound':4 'baloon':19 'boy':8 'butler':16 'cowboy':1 'doom':2 'drama':5 'fight':14 'lumberjack':11 'must':13
186	CRAFT OUTFIELD	A Lacklusture Display of a Explorer And a Hunter who must Succumb a Database Administrator in A Baloon Factory	2006	1	\N	6	0.99	64	17.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'administr':17 'baloon':20 'craft':1 'databas':16 'display':5 'explor':8 'factori':21 'hunter':11 'lacklustur':4 'must':13 'outfield':2 'succumb':14
187	CRANES RESERVOIR	A Fanciful Documentary of a Teacher And a Dog who must Outgun a Forensic Psychologist in A Baloon Factory	2006	1	\N	5	2.99	57	12.99	NC-17	2006-02-15 05:03:42	{Commentaries}	'baloon':20 'crane':1 'documentari':5 'dog':11 'factori':21 'fanci':4 'forens':16 'must':13 'outgun':14 'psychologist':17 'reservoir':2 'teacher':8
188	CRAZY HOME	A Fanciful Panorama of a Boy And a Woman who must Vanquish a Database Administrator in The Outback	2006	1	\N	7	2.99	136	24.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'administr':17 'boy':8 'crazi':1 'databas':16 'fanci':4 'home':2 'must':13 'outback':20 'panorama':5 'vanquish':14 'woman':11
189	CREATURES SHAKESPEARE	A Emotional Drama of a Womanizer And a Squirrel who must Vanquish a Crocodile in Ancient India	2006	1	\N	3	0.99	139	23.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'ancient':18 'creatur':1 'crocodil':16 'drama':5 'emot':4 'india':19 'must':13 'shakespear':2 'squirrel':11 'vanquish':14 'woman':8
190	CREEPERS KANE	A Awe-Inspiring Reflection of a Squirrel And a Boat who must Outrace a Car in A Jet Boat	2006	1	\N	5	4.99	172	23.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'awe':5 'awe-inspir':4 'boat':13,22 'car':18 'creeper':1 'inspir':6 'jet':21 'kane':2 'must':15 'outrac':16 'reflect':7 'squirrel':10
191	CROOKED FROGMEN	A Unbelieveable Drama of a Hunter And a Database Administrator who must Battle a Crocodile in An Abandoned Amusement Park	2006	1	\N	6	0.99	143	27.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':20 'administr':12 'amus':21 'battl':15 'crocodil':17 'crook':1 'databas':11 'drama':5 'frogmen':2 'hunter':8 'must':14 'park':22 'unbeliev':4
192	CROSSING DIVORCE	A Beautiful Documentary of a Dog And a Robot who must Redeem a Womanizer in Berlin	2006	1	\N	4	4.99	50	19.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'beauti':4 'berlin':18 'cross':1 'divorc':2 'documentari':5 'dog':8 'must':13 'redeem':14 'robot':11 'woman':16
193	CROSSROADS CASUALTIES	A Intrepid Documentary of a Sumo Wrestler And a Astronaut who must Battle a Composer in The Outback	2006	1	\N	5	2.99	153	20.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'astronaut':12 'battl':15 'casualti':2 'compos':17 'crossroad':1 'documentari':5 'intrepid':4 'must':14 'outback':20 'sumo':8 'wrestler':9
194	CROW GREASE	A Awe-Inspiring Documentary of a Woman And a Husband who must Sink a Database Administrator in The First Manned Space Station	2006	1	\N	6	0.99	104	22.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'administr':19 'awe':5 'awe-inspir':4 'crow':1 'databas':18 'documentari':7 'first':22 'greas':2 'husband':13 'inspir':6 'man':23 'must':15 'sink':16 'space':24 'station':25 'woman':10
195	CROWDS TELEMARK	A Intrepid Documentary of a Astronaut And a Forensic Psychologist who must Find a Frisbee in An Abandoned Fun House	2006	1	\N	3	4.99	112	16.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'abandon':20 'astronaut':8 'crowd':1 'documentari':5 'find':15 'forens':11 'frisbe':17 'fun':21 'hous':22 'intrepid':4 'must':14 'psychologist':12 'telemark':2
196	CRUELTY UNFORGIVEN	A Brilliant Tale of a Car And a Moose who must Battle a Dentist in Nigeria	2006	1	\N	7	0.99	69	29.99	G	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'battl':14 'brilliant':4 'car':8 'cruelti':1 'dentist':16 'moos':11 'must':13 'nigeria':18 'tale':5 'unforgiven':2
197	CRUSADE HONEY	A Fast-Paced Reflection of a Explorer And a Butler who must Battle a Madman in An Abandoned Amusement Park	2006	1	\N	4	2.99	112	27.99	R	2006-02-15 05:03:42	{Commentaries}	'abandon':21 'amus':22 'battl':16 'butler':13 'crusad':1 'explor':10 'fast':5 'fast-pac':4 'honey':2 'madman':18 'must':15 'pace':6 'park':23 'reflect':7
198	CRYSTAL BREAKING	A Fast-Paced Character Study of a Feminist And a Explorer who must Face a Pastry Chef in Ancient Japan	2006	1	\N	6	2.99	184	22.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries}	'ancient':22 'break':2 'charact':7 'chef':20 'crystal':1 'explor':14 'face':17 'fast':5 'fast-pac':4 'feminist':11 'japan':23 'must':16 'pace':6 'pastri':19 'studi':8
199	CUPBOARD SINNERS	A Emotional Reflection of a Frisbee And a Boat who must Reach a Pastry Chef in An Abandoned Amusement Park	2006	1	\N	4	2.99	56	29.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'abandon':20 'amus':21 'boat':11 'chef':17 'cupboard':1 'emot':4 'frisbe':8 'must':13 'park':22 'pastri':16 'reach':14 'reflect':5 'sinner':2
200	CURTAIN VIDEOTAPE	A Boring Reflection of a Dentist And a Mad Cow who must Chase a Secret Agent in A Shark Tank	2006	1	\N	7	0.99	133	27.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'agent':18 'bore':4 'chase':15 'cow':12 'curtain':1 'dentist':8 'mad':11 'must':14 'reflect':5 'secret':17 'shark':21 'tank':22 'videotap':2
201	CYCLONE FAMILY	A Lacklusture Drama of a Student And a Monkey who must Sink a Womanizer in A MySQL Convention	2006	1	\N	7	2.99	176	18.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'convent':20 'cyclon':1 'drama':5 'famili':2 'lacklustur':4 'monkey':11 'must':13 'mysql':19 'sink':14 'student':8 'woman':16
202	DADDY PITTSBURGH	A Epic Story of a A Shark And a Student who must Confront a Explorer in The Gulf of Mexico	2006	1	\N	5	4.99	161	26.99	G	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'confront':15 'daddi':1 'epic':4 'explor':17 'gulf':20 'mexico':22 'must':14 'pittsburgh':2 'shark':9 'stori':5 'student':12
203	DAISY MENAGERIE	A Fast-Paced Saga of a Pastry Chef And a Monkey who must Sink a Composer in Ancient India	2006	1	\N	5	4.99	84	9.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'ancient':21 'chef':11 'compos':19 'daisi':1 'fast':5 'fast-pac':4 'india':22 'menageri':2 'monkey':14 'must':16 'pace':6 'pastri':10 'saga':7 'sink':17
204	DALMATIONS SWEDEN	A Emotional Epistle of a Moose And a Hunter who must Overcome a Robot in A Manhattan Penthouse	2006	1	\N	4	0.99	106	25.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'dalmat':1 'emot':4 'epistl':5 'hunter':11 'manhattan':19 'moos':8 'must':13 'overcom':14 'penthous':20 'robot':16 'sweden':2
205	DANCES NONE	A Insightful Reflection of a A Shark And a Dog who must Kill a Butler in An Abandoned Amusement Park	2006	1	\N	3	0.99	58	22.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':20 'amus':21 'butler':17 'danc':1 'dog':12 'insight':4 'kill':15 'must':14 'none':2 'park':22 'reflect':5 'shark':9
206	DANCING FEVER	A Stunning Story of a Explorer And a Forensic Psychologist who must Face a Crocodile in A Shark Tank	2006	1	\N	6	0.99	144	25.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'crocodil':17 'danc':1 'explor':8 'face':15 'fever':2 'forens':11 'must':14 'psychologist':12 'shark':20 'stori':5 'stun':4 'tank':21
207	DANGEROUS UPTOWN	A Unbelieveable Story of a Mad Scientist And a Woman who must Overcome a Dog in California	2006	1	\N	7	4.99	121	26.99	PG	2006-02-15 05:03:42	{Commentaries}	'california':19 'danger':1 'dog':17 'mad':8 'must':14 'overcom':15 'scientist':9 'stori':5 'unbeliev':4 'uptown':2 'woman':12
208	DARES PLUTO	A Fateful Story of a Robot And a Dentist who must Defeat a Astronaut in New Orleans	2006	1	\N	7	2.99	89	16.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'astronaut':16 'dare':1 'defeat':14 'dentist':11 'fate':4 'must':13 'new':18 'orlean':19 'pluto':2 'robot':8 'stori':5
209	DARKNESS WAR	A Touching Documentary of a Husband And a Hunter who must Escape a Boy in The Sahara Desert	2006	1	\N	6	2.99	99	24.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'boy':16 'dark':1 'desert':20 'documentari':5 'escap':14 'hunter':11 'husband':8 'must':13 'sahara':19 'touch':4 'war':2
210	DARKO DORADO	A Stunning Reflection of a Frisbee And a Husband who must Redeem a Dog in New Orleans	2006	1	\N	3	4.99	130	13.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'darko':1 'dog':16 'dorado':2 'frisbe':8 'husband':11 'must':13 'new':18 'orlean':19 'redeem':14 'reflect':5 'stun':4
211	DARLING BREAKING	A Brilliant Documentary of a Astronaut And a Squirrel who must Succumb a Student in The Gulf of Mexico	2006	1	\N	7	4.99	165	20.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'astronaut':8 'break':2 'brilliant':4 'darl':1 'documentari':5 'gulf':19 'mexico':21 'must':13 'squirrel':11 'student':16 'succumb':14
212	DARN FORRESTER	A Fateful Story of a A Shark And a Explorer who must Succumb a Technical Writer in A Jet Boat	2006	1	\N	7	4.99	185	14.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'boat':22 'darn':1 'explor':12 'fate':4 'forrest':2 'jet':21 'must':14 'shark':9 'stori':5 'succumb':15 'technic':17 'writer':18
213	DATE SPEED	A Touching Saga of a Composer And a Moose who must Discover a Dentist in A MySQL Convention	2006	1	\N	4	0.99	104	19.99	R	2006-02-15 05:03:42	{Commentaries}	'compos':8 'convent':20 'date':1 'dentist':16 'discov':14 'moos':11 'must':13 'mysql':19 'saga':5 'speed':2 'touch':4
214	DAUGHTER MADIGAN	A Beautiful Tale of a Hunter And a Mad Scientist who must Confront a Squirrel in The First Manned Space Station	2006	1	\N	3	4.99	59	13.99	PG-13	2006-02-15 05:03:42	{Trailers}	'beauti':4 'confront':15 'daughter':1 'first':20 'hunter':8 'mad':11 'madigan':2 'man':21 'must':14 'scientist':12 'space':22 'squirrel':17 'station':23 'tale':5
215	DAWN POND	A Thoughtful Documentary of a Dentist And a Forensic Psychologist who must Defeat a Waitress in Berlin	2006	1	\N	4	4.99	57	27.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'berlin':19 'dawn':1 'defeat':15 'dentist':8 'documentari':5 'forens':11 'must':14 'pond':2 'psychologist':12 'thought':4 'waitress':17
216	DAY UNFAITHFUL	A Stunning Documentary of a Composer And a Mad Scientist who must Find a Technical Writer in A U-Boat	2006	1	\N	3	4.99	113	16.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'boat':23 'compos':8 'day':1 'documentari':5 'find':15 'mad':11 'must':14 'scientist':12 'stun':4 'technic':17 'u':22 'u-boat':21 'unfaith':2 'writer':18
217	DAZED PUNK	A Action-Packed Story of a Pioneer And a Technical Writer who must Discover a Forensic Psychologist in An Abandoned Amusement Park	2006	1	\N	6	4.99	120	20.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'abandon':23 'action':5 'action-pack':4 'amus':24 'daze':1 'discov':17 'forens':19 'must':16 'pack':6 'park':25 'pioneer':10 'psychologist':20 'punk':2 'stori':7 'technic':13 'writer':14
218	DECEIVER BETRAYED	A Taut Story of a Moose And a Squirrel who must Build a Husband in Ancient India	2006	1	\N	7	0.99	122	22.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'ancient':18 'betray':2 'build':14 'deceiv':1 'husband':16 'india':19 'moos':8 'must':13 'squirrel':11 'stori':5 'taut':4
219	DEEP CRUSADE	A Amazing Tale of a Crocodile And a Squirrel who must Discover a Composer in Australia	2006	1	\N	6	4.99	51	20.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'amaz':4 'australia':18 'compos':16 'crocodil':8 'crusad':2 'deep':1 'discov':14 'must':13 'squirrel':11 'tale':5
220	DEER VIRGINIAN	A Thoughtful Story of a Mad Cow And a Womanizer who must Overcome a Mad Scientist in Soviet Georgia	2006	1	\N	7	2.99	106	13.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes"}	'cow':9 'deer':1 'georgia':21 'mad':8,17 'must':14 'overcom':15 'scientist':18 'soviet':20 'stori':5 'thought':4 'virginian':2 'woman':12
221	DELIVERANCE MULHOLLAND	A Astounding Saga of a Monkey And a Moose who must Conquer a Butler in A Shark Tank	2006	1	\N	4	0.99	100	9.99	R	2006-02-15 05:03:42	{"Deleted Scenes"}	'astound':4 'butler':16 'conquer':14 'deliver':1 'monkey':8 'moos':11 'mulholland':2 'must':13 'saga':5 'shark':19 'tank':20
222	DESERT POSEIDON	A Brilliant Documentary of a Butler And a Frisbee who must Build a Astronaut in New Orleans	2006	1	\N	4	4.99	64	27.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'astronaut':16 'brilliant':4 'build':14 'butler':8 'desert':1 'documentari':5 'frisbe':11 'must':13 'new':18 'orlean':19 'poseidon':2
223	DESIRE ALIEN	A Fast-Paced Tale of a Dog And a Forensic Psychologist who must Meet a Astronaut in The First Manned Space Station	2006	1	\N	7	2.99	76	24.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes"}	'alien':2 'astronaut':19 'desir':1 'dog':10 'fast':5 'fast-pac':4 'first':22 'forens':13 'man':23 'meet':17 'must':16 'pace':6 'psychologist':14 'space':24 'station':25 'tale':7
224	DESPERATE TRAINSPOTTING	A Epic Yarn of a Forensic Psychologist And a Teacher who must Face a Lumberjack in California	2006	1	\N	7	4.99	81	29.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'california':19 'desper':1 'epic':4 'face':15 'forens':8 'lumberjack':17 'must':14 'psychologist':9 'teacher':12 'trainspot':2 'yarn':5
225	DESTINATION JERK	A Beautiful Yarn of a Teacher And a Cat who must Build a Car in A U-Boat	2006	1	\N	3	0.99	76	19.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'beauti':4 'boat':21 'build':14 'car':16 'cat':11 'destin':1 'jerk':2 'must':13 'teacher':8 'u':20 'u-boat':19 'yarn':5
226	DESTINY SATURDAY	A Touching Drama of a Crocodile And a Crocodile who must Conquer a Explorer in Soviet Georgia	2006	1	\N	4	4.99	56	20.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'conquer':14 'crocodil':8,11 'destini':1 'drama':5 'explor':16 'georgia':19 'must':13 'saturday':2 'soviet':18 'touch':4
227	DETAILS PACKER	A Epic Saga of a Waitress And a Composer who must Face a Boat in A U-Boat	2006	1	\N	4	4.99	88	17.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'boat':16,21 'compos':11 'detail':1 'epic':4 'face':14 'must':13 'packer':2 'saga':5 'u':20 'u-boat':19 'waitress':8
228	DETECTIVE VISION	A Fanciful Documentary of a Pioneer And a Woman who must Redeem a Hunter in Ancient Japan	2006	1	\N	4	0.99	143	16.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'ancient':18 'detect':1 'documentari':5 'fanci':4 'hunter':16 'japan':19 'must':13 'pioneer':8 'redeem':14 'vision':2 'woman':11
229	DEVIL DESIRE	A Beautiful Reflection of a Monkey And a Dentist who must Face a Database Administrator in Ancient Japan	2006	1	\N	6	4.99	87	12.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'administr':17 'ancient':19 'beauti':4 'databas':16 'dentist':11 'desir':2 'devil':1 'face':14 'japan':20 'monkey':8 'must':13 'reflect':5
230	DIARY PANIC	A Thoughtful Character Study of a Frisbee And a Mad Cow who must Outgun a Man in Ancient India	2006	1	\N	7	2.99	107	20.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'ancient':20 'charact':5 'cow':13 'diari':1 'frisbe':9 'india':21 'mad':12 'man':18 'must':15 'outgun':16 'panic':2 'studi':6 'thought':4
231	DINOSAUR SECRETARY	A Action-Packed Drama of a Feminist And a Girl who must Reach a Robot in The Canadian Rockies	2006	1	\N	7	2.99	63	27.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'action':5 'action-pack':4 'canadian':21 'dinosaur':1 'drama':7 'feminist':10 'girl':13 'must':15 'pack':6 'reach':16 'robot':18 'rocki':22 'secretari':2
232	DIRTY ACE	A Action-Packed Character Study of a Forensic Psychologist And a Girl who must Build a Dentist in The Outback	2006	1	\N	7	2.99	147	29.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'ace':2 'action':5 'action-pack':4 'build':18 'charact':7 'dentist':20 'dirti':1 'forens':11 'girl':15 'must':17 'outback':23 'pack':6 'psychologist':12 'studi':8
233	DISCIPLE MOTHER	A Touching Reflection of a Mad Scientist And a Boat who must Face a Moose in A Shark Tank	2006	1	\N	3	0.99	141	17.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'boat':12 'discipl':1 'face':15 'mad':8 'moos':17 'mother':2 'must':14 'reflect':5 'scientist':9 'shark':20 'tank':21 'touch':4
234	DISTURBING SCARFACE	A Lacklusture Display of a Crocodile And a Butler who must Overcome a Monkey in A U-Boat	2006	1	\N	6	2.99	94	27.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'boat':21 'butler':11 'crocodil':8 'display':5 'disturb':1 'lacklustur':4 'monkey':16 'must':13 'overcom':14 'scarfac':2 'u':20 'u-boat':19
235	DIVIDE MONSTER	A Intrepid Saga of a Man And a Forensic Psychologist who must Reach a Squirrel in A Monastery	2006	1	\N	6	2.99	68	13.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'divid':1 'forens':11 'intrepid':4 'man':8 'monasteri':20 'monster':2 'must':14 'psychologist':12 'reach':15 'saga':5 'squirrel':17
236	DIVINE RESURRECTION	A Boring Character Study of a Man And a Womanizer who must Succumb a Teacher in An Abandoned Amusement Park	2006	1	\N	4	2.99	100	19.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'abandon':20 'amus':21 'bore':4 'charact':5 'divin':1 'man':9 'must':14 'park':22 'resurrect':2 'studi':6 'succumb':15 'teacher':17 'woman':12
237	DIVORCE SHINING	A Unbelieveable Saga of a Crocodile And a Student who must Discover a Cat in Ancient India	2006	1	\N	3	2.99	47	21.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'ancient':18 'cat':16 'crocodil':8 'discov':14 'divorc':1 'india':19 'must':13 'saga':5 'shine':2 'student':11 'unbeliev':4
238	DOCTOR GRAIL	A Insightful Drama of a Womanizer And a Waitress who must Reach a Forensic Psychologist in The Outback	2006	1	\N	4	2.99	57	29.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'doctor':1 'drama':5 'forens':16 'grail':2 'insight':4 'must':13 'outback':20 'psychologist':17 'reach':14 'waitress':11 'woman':8
239	DOGMA FAMILY	A Brilliant Character Study of a Database Administrator And a Monkey who must Succumb a Astronaut in New Orleans	2006	1	\N	5	4.99	122	16.99	G	2006-02-15 05:03:42	{Commentaries}	'administr':10 'astronaut':18 'brilliant':4 'charact':5 'databas':9 'dogma':1 'famili':2 'monkey':13 'must':15 'new':20 'orlean':21 'studi':6 'succumb':16
240	DOLLS RAGE	A Thrilling Display of a Pioneer And a Frisbee who must Escape a Teacher in The Outback	2006	1	\N	7	2.99	120	10.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'display':5 'doll':1 'escap':14 'frisbe':11 'must':13 'outback':19 'pioneer':8 'rage':2 'teacher':16 'thrill':4
241	DONNIE ALLEY	A Awe-Inspiring Tale of a Butler And a Frisbee who must Vanquish a Teacher in Ancient Japan	2006	1	\N	4	0.99	125	20.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'alley':2 'ancient':20 'awe':5 'awe-inspir':4 'butler':10 'donni':1 'frisbe':13 'inspir':6 'japan':21 'must':15 'tale':7 'teacher':18 'vanquish':16
242	DOOM DANCING	A Astounding Panorama of a Car And a Mad Scientist who must Battle a Lumberjack in A MySQL Convention	2006	1	\N	4	0.99	68	13.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'astound':4 'battl':15 'car':8 'convent':21 'danc':2 'doom':1 'lumberjack':17 'mad':11 'must':14 'mysql':20 'panorama':5 'scientist':12
243	DOORS PRESIDENT	A Awe-Inspiring Display of a Squirrel And a Woman who must Overcome a Boy in The Gulf of Mexico	2006	1	\N	3	4.99	49	22.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'awe':5 'awe-inspir':4 'boy':18 'display':7 'door':1 'gulf':21 'inspir':6 'mexico':23 'must':15 'overcom':16 'presid':2 'squirrel':10 'woman':13
244	DORADO NOTTING	A Action-Packed Tale of a Sumo Wrestler And a A Shark who must Meet a Frisbee in California	2006	1	\N	5	4.99	139	26.99	NC-17	2006-02-15 05:03:42	{Commentaries}	'action':5 'action-pack':4 'california':22 'dorado':1 'frisbe':20 'meet':18 'must':17 'not':2 'pack':6 'shark':15 'sumo':10 'tale':7 'wrestler':11
245	DOUBLE WRATH	A Thoughtful Yarn of a Womanizer And a Dog who must Challenge a Madman in The Gulf of Mexico	2006	1	\N	4	0.99	177	28.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'challeng':14 'dog':11 'doubl':1 'gulf':19 'madman':16 'mexico':21 'must':13 'thought':4 'woman':8 'wrath':2 'yarn':5
246	DOUBTFIRE LABYRINTH	A Intrepid Panorama of a Butler And a Composer who must Meet a Mad Cow in The Sahara Desert	2006	1	\N	5	4.99	154	16.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'butler':8 'compos':11 'cow':17 'desert':21 'doubtfir':1 'intrepid':4 'labyrinth':2 'mad':16 'meet':14 'must':13 'panorama':5 'sahara':20
247	DOWNHILL ENOUGH	A Emotional Tale of a Pastry Chef And a Forensic Psychologist who must Succumb a Monkey in The Sahara Desert	2006	1	\N	3	0.99	47	19.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'chef':9 'desert':22 'downhil':1 'emot':4 'enough':2 'forens':12 'monkey':18 'must':15 'pastri':8 'psychologist':13 'sahara':21 'succumb':16 'tale':5
248	DOZEN LION	A Taut Drama of a Cat And a Girl who must Defeat a Frisbee in The Canadian Rockies	2006	1	\N	6	4.99	177	20.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'canadian':19 'cat':8 'defeat':14 'dozen':1 'drama':5 'frisbe':16 'girl':11 'lion':2 'must':13 'rocki':20 'taut':4
249	DRACULA CRYSTAL	A Thrilling Reflection of a Feminist And a Cat who must Find a Frisbee in An Abandoned Fun House	2006	1	\N	7	0.99	176	26.99	G	2006-02-15 05:03:42	{Commentaries}	'abandon':19 'cat':11 'crystal':2 'dracula':1 'feminist':8 'find':14 'frisbe':16 'fun':20 'hous':21 'must':13 'reflect':5 'thrill':4
250	DRAGON SQUAD	A Taut Reflection of a Boy And a Waitress who must Outgun a Teacher in Ancient China	2006	1	\N	4	0.99	170	26.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'ancient':18 'boy':8 'china':19 'dragon':1 'must':13 'outgun':14 'reflect':5 'squad':2 'taut':4 'teacher':16 'waitress':11
251	DRAGONFLY STRANGERS	A Boring Documentary of a Pioneer And a Man who must Vanquish a Man in Nigeria	2006	1	\N	6	4.99	133	19.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'bore':4 'documentari':5 'dragonfli':1 'man':11,16 'must':13 'nigeria':18 'pioneer':8 'stranger':2 'vanquish':14
252	DREAM PICKUP	A Epic Display of a Car And a Composer who must Overcome a Forensic Psychologist in The Gulf of Mexico	2006	1	\N	6	2.99	135	18.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'car':8 'compos':11 'display':5 'dream':1 'epic':4 'forens':16 'gulf':20 'mexico':22 'must':13 'overcom':14 'pickup':2 'psychologist':17
253	DRIFTER COMMANDMENTS	A Epic Reflection of a Womanizer And a Squirrel who must Discover a Husband in A Jet Boat	2006	1	\N	5	4.99	61	18.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'boat':20 'command':2 'discov':14 'drifter':1 'epic':4 'husband':16 'jet':19 'must':13 'reflect':5 'squirrel':11 'woman':8
254	DRIVER ANNIE	A Lacklusture Character Study of a Butler And a Car who must Redeem a Boat in An Abandoned Fun House	2006	1	\N	4	2.99	159	11.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'abandon':20 'anni':2 'boat':17 'butler':9 'car':12 'charact':5 'driver':1 'fun':21 'hous':22 'lacklustur':4 'must':14 'redeem':15 'studi':6
255	DRIVING POLISH	A Action-Packed Yarn of a Feminist And a Technical Writer who must Sink a Boat in An Abandoned Mine Shaft	2006	1	\N	6	4.99	175	21.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'abandon':22 'action':5 'action-pack':4 'boat':19 'drive':1 'feminist':10 'mine':23 'must':16 'pack':6 'polish':2 'shaft':24 'sink':17 'technic':13 'writer':14 'yarn':7
256	DROP WATERFRONT	A Fanciful Documentary of a Husband And a Explorer who must Reach a Madman in Ancient China	2006	1	\N	6	4.99	178	20.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'ancient':18 'china':19 'documentari':5 'drop':1 'explor':11 'fanci':4 'husband':8 'madman':16 'must':13 'reach':14 'waterfront':2
257	DRUMLINE CYCLONE	A Insightful Panorama of a Monkey And a Sumo Wrestler who must Outrace a Mad Scientist in The Canadian Rockies	2006	1	\N	3	0.99	110	14.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'canadian':21 'cyclon':2 'drumlin':1 'insight':4 'mad':17 'monkey':8 'must':14 'outrac':15 'panorama':5 'rocki':22 'scientist':18 'sumo':11 'wrestler':12
258	DRUMS DYNAMITE	A Epic Display of a Crocodile And a Crocodile who must Confront a Dog in An Abandoned Amusement Park	2006	1	\N	6	0.99	96	11.99	PG	2006-02-15 05:03:42	{Trailers}	'abandon':19 'amus':20 'confront':14 'crocodil':8,11 'display':5 'dog':16 'drum':1 'dynamit':2 'epic':4 'must':13 'park':21
259	DUCK RACER	A Lacklusture Yarn of a Teacher And a Squirrel who must Overcome a Dog in A Shark Tank	2006	1	\N	4	2.99	116	15.99	NC-17	2006-02-15 05:03:42	{"Behind the Scenes"}	'dog':16 'duck':1 'lacklustur':4 'must':13 'overcom':14 'racer':2 'shark':19 'squirrel':11 'tank':20 'teacher':8 'yarn':5
260	DUDE BLINDNESS	A Stunning Reflection of a Husband And a Lumberjack who must Face a Frisbee in An Abandoned Fun House	2006	1	\N	3	4.99	132	9.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'abandon':19 'blind':2 'dude':1 'face':14 'frisbe':16 'fun':20 'hous':21 'husband':8 'lumberjack':11 'must':13 'reflect':5 'stun':4
261	DUFFEL APOCALYPSE	A Emotional Display of a Boat And a Explorer who must Challenge a Madman in A MySQL Convention	2006	1	\N	5	0.99	171	13.99	G	2006-02-15 05:03:42	{Commentaries}	'apocalyps':2 'boat':8 'challeng':14 'convent':20 'display':5 'duffel':1 'emot':4 'explor':11 'madman':16 'must':13 'mysql':19
262	DUMBO LUST	A Touching Display of a Feminist And a Dentist who must Conquer a Husband in The Gulf of Mexico	2006	1	\N	5	0.99	119	17.99	NC-17	2006-02-15 05:03:42	{"Behind the Scenes"}	'conquer':14 'dentist':11 'display':5 'dumbo':1 'feminist':8 'gulf':19 'husband':16 'lust':2 'mexico':21 'must':13 'touch':4
263	DURHAM PANKY	A Brilliant Panorama of a Girl And a Boy who must Face a Mad Scientist in An Abandoned Mine Shaft	2006	1	\N	6	4.99	154	14.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'abandon':20 'boy':11 'brilliant':4 'durham':1 'face':14 'girl':8 'mad':16 'mine':21 'must':13 'panki':2 'panorama':5 'scientist':17 'shaft':22
264	DWARFS ALTER	A Emotional Yarn of a Girl And a Dog who must Challenge a Composer in Ancient Japan	2006	1	\N	6	2.99	101	13.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'alter':2 'ancient':18 'challeng':14 'compos':16 'dog':11 'dwarf':1 'emot':4 'girl':8 'japan':19 'must':13 'yarn':5
265	DYING MAKER	A Intrepid Tale of a Boat And a Monkey who must Kill a Cat in California	2006	1	\N	5	4.99	168	28.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'boat':8 'california':18 'cat':16 'die':1 'intrepid':4 'kill':14 'maker':2 'monkey':11 'must':13 'tale':5
266	DYNAMITE TARZAN	A Intrepid Documentary of a Forensic Psychologist And a Mad Scientist who must Face a Explorer in A U-Boat	2006	1	\N	4	0.99	141	27.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'boat':23 'documentari':5 'dynamit':1 'explor':18 'face':16 'forens':8 'intrepid':4 'mad':12 'must':15 'psychologist':9 'scientist':13 'tarzan':2 'u':22 'u-boat':21
267	EAGLES PANKY	A Thoughtful Story of a Car And a Boy who must Find a A Shark in The Sahara Desert	2006	1	\N	4	4.99	140	14.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'boy':11 'car':8 'desert':21 'eagl':1 'find':14 'must':13 'panki':2 'sahara':20 'shark':17 'stori':5 'thought':4
268	EARLY HOME	A Amazing Panorama of a Mad Scientist And a Husband who must Meet a Woman in The Outback	2006	1	\N	6	4.99	96	27.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'amaz':4 'earli':1 'home':2 'husband':12 'mad':8 'meet':15 'must':14 'outback':20 'panorama':5 'scientist':9 'woman':17
269	EARRING INSTINCT	A Stunning Character Study of a Dentist And a Mad Cow who must Find a Teacher in Nigeria	2006	1	\N	3	0.99	98	22.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'charact':5 'cow':13 'dentist':9 'earring':1 'find':16 'instinct':2 'mad':12 'must':15 'nigeria':20 'studi':6 'stun':4 'teacher':18
270	EARTH VISION	A Stunning Drama of a Butler And a Madman who must Outrace a Womanizer in Ancient India	2006	1	\N	7	0.99	85	29.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'ancient':18 'butler':8 'drama':5 'earth':1 'india':19 'madman':11 'must':13 'outrac':14 'stun':4 'vision':2 'woman':16
271	EASY GLADIATOR	A Fateful Story of a Monkey And a Girl who must Overcome a Pastry Chef in Ancient India	2006	1	\N	5	4.99	148	12.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'ancient':19 'chef':17 'easi':1 'fate':4 'girl':11 'gladiat':2 'india':20 'monkey':8 'must':13 'overcom':14 'pastri':16 'stori':5
272	EDGE KISSING	A Beautiful Yarn of a Composer And a Mad Cow who must Redeem a Mad Scientist in A Jet Boat	2006	1	\N	5	4.99	153	9.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes"}	'beauti':4 'boat':22 'compos':8 'cow':12 'edg':1 'jet':21 'kiss':2 'mad':11,17 'must':14 'redeem':15 'scientist':18 'yarn':5
273	EFFECT GLADIATOR	A Beautiful Display of a Pastry Chef And a Pastry Chef who must Outgun a Forensic Psychologist in A Manhattan Penthouse	2006	1	\N	6	0.99	107	14.99	PG	2006-02-15 05:03:42	{Commentaries}	'beauti':4 'chef':9,13 'display':5 'effect':1 'forens':18 'gladiat':2 'manhattan':22 'must':15 'outgun':16 'pastri':8,12 'penthous':23 'psychologist':19
274	EGG IGBY	A Beautiful Documentary of a Boat And a Sumo Wrestler who must Succumb a Database Administrator in The First Manned Space Station	2006	1	\N	4	2.99	67	20.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'administr':18 'beauti':4 'boat':8 'databas':17 'documentari':5 'egg':1 'first':21 'igbi':2 'man':22 'must':14 'space':23 'station':24 'succumb':15 'sumo':11 'wrestler':12
275	EGYPT TENENBAUMS	A Intrepid Story of a Madman And a Secret Agent who must Outrace a Astronaut in An Abandoned Amusement Park	2006	1	\N	3	0.99	85	11.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':20 'agent':12 'amus':21 'astronaut':17 'egypt':1 'intrepid':4 'madman':8 'must':14 'outrac':15 'park':22 'secret':11 'stori':5 'tenenbaum':2
276	ELEMENT FREDDY	A Awe-Inspiring Reflection of a Waitress And a Squirrel who must Kill a Mad Cow in A Jet Boat	2006	1	\N	6	4.99	115	28.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'awe':5 'awe-inspir':4 'boat':23 'cow':19 'element':1 'freddi':2 'inspir':6 'jet':22 'kill':16 'mad':18 'must':15 'reflect':7 'squirrel':13 'waitress':10
277	ELEPHANT TROJAN	A Beautiful Panorama of a Lumberjack And a Forensic Psychologist who must Overcome a Frisbee in A Baloon	2006	1	\N	4	4.99	126	24.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'baloon':20 'beauti':4 'eleph':1 'forens':11 'frisbe':17 'lumberjack':8 'must':14 'overcom':15 'panorama':5 'psychologist':12 'trojan':2
278	ELF MURDER	A Action-Packed Story of a Frisbee And a Woman who must Reach a Girl in An Abandoned Mine Shaft	2006	1	\N	4	4.99	155	19.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'abandon':21 'action':5 'action-pack':4 'elf':1 'frisbe':10 'girl':18 'mine':22 'murder':2 'must':15 'pack':6 'reach':16 'shaft':23 'stori':7 'woman':13
279	ELIZABETH SHANE	A Lacklusture Display of a Womanizer And a Dog who must Face a Sumo Wrestler in Ancient Japan	2006	1	\N	7	4.99	152	11.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'ancient':19 'display':5 'dog':11 'elizabeth':1 'face':14 'japan':20 'lacklustur':4 'must':13 'shane':2 'sumo':16 'woman':8 'wrestler':17
280	EMPIRE MALKOVICH	A Amazing Story of a Feminist And a Cat who must Face a Car in An Abandoned Fun House	2006	1	\N	7	0.99	177	26.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'abandon':19 'amaz':4 'car':16 'cat':11 'empir':1 'face':14 'feminist':8 'fun':20 'hous':21 'malkovich':2 'must':13 'stori':5
281	ENCINO ELF	A Astounding Drama of a Feminist And a Teacher who must Confront a Husband in A Baloon	2006	1	\N	6	0.99	143	9.99	G	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'astound':4 'baloon':19 'confront':14 'drama':5 'elf':2 'encino':1 'feminist':8 'husband':16 'must':13 'teacher':11
282	ENCOUNTERS CURTAIN	A Insightful Epistle of a Pastry Chef And a Womanizer who must Build a Boat in New Orleans	2006	1	\N	5	0.99	92	20.99	NC-17	2006-02-15 05:03:42	{Trailers}	'boat':17 'build':15 'chef':9 'curtain':2 'encount':1 'epistl':5 'insight':4 'must':14 'new':19 'orlean':20 'pastri':8 'woman':12
283	ENDING CROWDS	A Unbelieveable Display of a Dentist And a Madman who must Vanquish a Squirrel in Berlin	2006	1	\N	6	0.99	85	10.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'berlin':18 'crowd':2 'dentist':8 'display':5 'end':1 'madman':11 'must':13 'squirrel':16 'unbeliev':4 'vanquish':14
284	ENEMY ODDS	A Fanciful Panorama of a Mad Scientist And a Woman who must Pursue a Astronaut in Ancient India	2006	1	\N	5	4.99	77	23.99	NC-17	2006-02-15 05:03:42	{Trailers}	'ancient':19 'astronaut':17 'enemi':1 'fanci':4 'india':20 'mad':8 'must':14 'odd':2 'panorama':5 'pursu':15 'scientist':9 'woman':12
285	ENGLISH BULWORTH	A Intrepid Epistle of a Pastry Chef And a Pastry Chef who must Pursue a Crocodile in Ancient China	2006	1	\N	3	0.99	51	18.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'ancient':20 'bulworth':2 'chef':9,13 'china':21 'crocodil':18 'english':1 'epistl':5 'intrepid':4 'must':15 'pastri':8,12 'pursu':16
286	ENOUGH RAGING	A Astounding Character Study of a Boat And a Secret Agent who must Find a Mad Cow in The Sahara Desert	2006	1	\N	7	2.99	158	16.99	NC-17	2006-02-15 05:03:42	{Commentaries}	'agent':13 'astound':4 'boat':9 'charact':5 'cow':19 'desert':23 'enough':1 'find':16 'mad':18 'must':15 'rage':2 'sahara':22 'secret':12 'studi':6
287	ENTRAPMENT SATISFACTION	A Thoughtful Panorama of a Hunter And a Teacher who must Reach a Mad Cow in A U-Boat	2006	1	\N	5	0.99	176	19.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'boat':22 'cow':17 'entrap':1 'hunter':8 'mad':16 'must':13 'panorama':5 'reach':14 'satisfact':2 'teacher':11 'thought':4 'u':21 'u-boat':20
288	ESCAPE METROPOLIS	A Taut Yarn of a Astronaut And a Technical Writer who must Outgun a Boat in New Orleans	2006	1	\N	7	2.99	167	20.99	R	2006-02-15 05:03:42	{Trailers}	'astronaut':8 'boat':17 'escap':1 'metropoli':2 'must':14 'new':19 'orlean':20 'outgun':15 'taut':4 'technic':11 'writer':12 'yarn':5
289	EVE RESURRECTION	A Awe-Inspiring Yarn of a Pastry Chef And a Database Administrator who must Challenge a Teacher in A Baloon	2006	1	\N	5	4.99	66	25.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'administr':15 'awe':5 'awe-inspir':4 'baloon':23 'challeng':18 'chef':11 'databas':14 'eve':1 'inspir':6 'must':17 'pastri':10 'resurrect':2 'teacher':20 'yarn':7
290	EVERYONE CRAFT	A Fateful Display of a Waitress And a Dentist who must Reach a Butler in Nigeria	2006	1	\N	4	0.99	163	29.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'butler':16 'craft':2 'dentist':11 'display':5 'everyon':1 'fate':4 'must':13 'nigeria':18 'reach':14 'waitress':8
291	EVOLUTION ALTER	A Fanciful Character Study of a Feminist And a Madman who must Find a Explorer in A Baloon Factory	2006	1	\N	5	0.99	174	10.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'alter':2 'baloon':20 'charact':5 'evolut':1 'explor':17 'factori':21 'fanci':4 'feminist':9 'find':15 'madman':12 'must':14 'studi':6
292	EXCITEMENT EVE	A Brilliant Documentary of a Monkey And a Car who must Conquer a Crocodile in A Shark Tank	2006	1	\N	3	0.99	51	20.99	G	2006-02-15 05:03:42	{Commentaries}	'brilliant':4 'car':11 'conquer':14 'crocodil':16 'documentari':5 'eve':2 'excit':1 'monkey':8 'must':13 'shark':19 'tank':20
293	EXORCIST STING	A Touching Drama of a Dog And a Sumo Wrestler who must Conquer a Mad Scientist in Berlin	2006	1	\N	6	2.99	167	17.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'berlin':20 'conquer':15 'dog':8 'drama':5 'exorcist':1 'mad':17 'must':14 'scientist':18 'sting':2 'sumo':11 'touch':4 'wrestler':12
294	EXPECATIONS NATURAL	A Amazing Drama of a Butler And a Husband who must Reach a A Shark in A U-Boat	2006	1	\N	5	4.99	138	26.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'amaz':4 'boat':22 'butler':8 'drama':5 'expec':1 'husband':11 'must':13 'natur':2 'reach':14 'shark':17 'u':21 'u-boat':20
295	EXPENDABLE STALLION	A Amazing Character Study of a Mad Cow And a Squirrel who must Discover a Hunter in A U-Boat	2006	1	\N	3	0.99	97	14.99	PG	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'amaz':4 'boat':23 'charact':5 'cow':10 'discov':16 'expend':1 'hunter':18 'mad':9 'must':15 'squirrel':13 'stallion':2 'studi':6 'u':22 'u-boat':21
296	EXPRESS LONELY	A Boring Drama of a Astronaut And a Boat who must Face a Boat in California	2006	1	\N	5	2.99	178	23.99	R	2006-02-15 05:03:42	{Trailers}	'astronaut':8 'boat':11,16 'bore':4 'california':18 'drama':5 'express':1 'face':14 'lone':2 'must':13
297	EXTRAORDINARY CONQUERER	A Stunning Story of a Dog And a Feminist who must Face a Forensic Psychologist in Berlin	2006	1	\N	6	2.99	122	29.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'berlin':19 'conquer':2 'dog':8 'extraordinari':1 'face':14 'feminist':11 'forens':16 'must':13 'psychologist':17 'stori':5 'stun':4
298	EYES DRIVING	A Thrilling Story of a Cat And a Waitress who must Fight a Explorer in The Outback	2006	1	\N	4	2.99	172	13.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'cat':8 'drive':2 'explor':16 'eye':1 'fight':14 'must':13 'outback':19 'stori':5 'thrill':4 'waitress':11
299	FACTORY DRAGON	A Action-Packed Saga of a Teacher And a Frisbee who must Escape a Lumberjack in The Sahara Desert	2006	1	\N	4	0.99	144	9.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'action':5 'action-pack':4 'desert':22 'dragon':2 'escap':16 'factori':1 'frisbe':13 'lumberjack':18 'must':15 'pack':6 'saga':7 'sahara':21 'teacher':10
300	FALCON VOLUME	A Fateful Saga of a Sumo Wrestler And a Hunter who must Redeem a A Shark in New Orleans	2006	1	\N	5	4.99	102	21.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'falcon':1 'fate':4 'hunter':12 'must':14 'new':20 'orlean':21 'redeem':15 'saga':5 'shark':18 'sumo':8 'volum':2 'wrestler':9
301	FAMILY SWEET	A Epic Documentary of a Teacher And a Boy who must Escape a Woman in Berlin	2006	1	\N	4	0.99	155	24.99	R	2006-02-15 05:03:42	{Trailers}	'berlin':18 'boy':11 'documentari':5 'epic':4 'escap':14 'famili':1 'must':13 'sweet':2 'teacher':8 'woman':16
302	FANTASIA PARK	A Thoughtful Documentary of a Mad Scientist And a A Shark who must Outrace a Feminist in Australia	2006	1	\N	5	2.99	131	29.99	G	2006-02-15 05:03:42	{Commentaries}	'australia':20 'documentari':5 'fantasia':1 'feminist':18 'mad':8 'must':15 'outrac':16 'park':2 'scientist':9 'shark':13 'thought':4
303	FANTASY TROOPERS	A Touching Saga of a Teacher And a Monkey who must Overcome a Secret Agent in A MySQL Convention	2006	1	\N	6	0.99	58	27.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'agent':17 'convent':21 'fantasi':1 'monkey':11 'must':13 'mysql':20 'overcom':14 'saga':5 'secret':16 'teacher':8 'touch':4 'trooper':2
304	FARGO GANDHI	A Thrilling Reflection of a Pastry Chef And a Crocodile who must Reach a Teacher in The Outback	2006	1	\N	3	2.99	130	28.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'chef':9 'crocodil':12 'fargo':1 'gandhi':2 'must':14 'outback':20 'pastri':8 'reach':15 'reflect':5 'teacher':17 'thrill':4
305	FATAL HAUNTED	A Beautiful Drama of a Student And a Secret Agent who must Confront a Dentist in Ancient Japan	2006	1	\N	6	2.99	91	24.99	PG	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'agent':12 'ancient':19 'beauti':4 'confront':15 'dentist':17 'drama':5 'fatal':1 'haunt':2 'japan':20 'must':14 'secret':11 'student':8
306	FEATHERS METAL	A Thoughtful Yarn of a Monkey And a Teacher who must Find a Dog in Australia	2006	1	\N	3	0.99	104	12.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'australia':18 'dog':16 'feather':1 'find':14 'metal':2 'monkey':8 'must':13 'teacher':11 'thought':4 'yarn':5
307	FELLOWSHIP AUTUMN	A Lacklusture Reflection of a Dentist And a Hunter who must Meet a Teacher in A Baloon	2006	1	\N	6	4.99	77	9.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'autumn':2 'baloon':19 'dentist':8 'fellowship':1 'hunter':11 'lacklustur':4 'meet':14 'must':13 'reflect':5 'teacher':16
308	FERRIS MOTHER	A Touching Display of a Frisbee And a Frisbee who must Kill a Girl in The Gulf of Mexico	2006	1	\N	3	2.99	142	13.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'display':5 'ferri':1 'frisbe':8,11 'girl':16 'gulf':19 'kill':14 'mexico':21 'mother':2 'must':13 'touch':4
309	FEUD FROGMEN	A Brilliant Reflection of a Database Administrator And a Mad Cow who must Chase a Woman in The Canadian Rockies	2006	1	\N	6	0.99	98	29.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'administr':9 'brilliant':4 'canadian':21 'chase':16 'cow':13 'databas':8 'feud':1 'frogmen':2 'mad':12 'must':15 'reflect':5 'rocki':22 'woman':18
310	FEVER EMPIRE	A Insightful Panorama of a Cat And a Boat who must Defeat a Boat in The Gulf of Mexico	2006	1	\N	5	4.99	158	20.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'boat':11,16 'cat':8 'defeat':14 'empir':2 'fever':1 'gulf':19 'insight':4 'mexico':21 'must':13 'panorama':5
311	FICTION CHRISTMAS	A Emotional Yarn of a A Shark And a Student who must Battle a Robot in An Abandoned Mine Shaft	2006	1	\N	4	0.99	72	14.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':20 'battl':15 'christma':2 'emot':4 'fiction':1 'mine':21 'must':14 'robot':17 'shaft':22 'shark':9 'student':12 'yarn':5
312	FIDDLER LOST	A Boring Tale of a Squirrel And a Dog who must Challenge a Madman in The Gulf of Mexico	2006	1	\N	4	4.99	75	20.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'bore':4 'challeng':14 'dog':11 'fiddler':1 'gulf':19 'lost':2 'madman':16 'mexico':21 'must':13 'squirrel':8 'tale':5
313	FIDELITY DEVIL	A Awe-Inspiring Drama of a Technical Writer And a Composer who must Reach a Pastry Chef in A U-Boat	2006	1	\N	5	4.99	118	11.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'awe':5 'awe-inspir':4 'boat':25 'chef':20 'compos':14 'devil':2 'drama':7 'fidel':1 'inspir':6 'must':16 'pastri':19 'reach':17 'technic':10 'u':24 'u-boat':23 'writer':11
314	FIGHT JAWBREAKER	A Intrepid Panorama of a Womanizer And a Girl who must Escape a Girl in A Manhattan Penthouse	2006	1	\N	3	0.99	91	13.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'escap':14 'fight':1 'girl':11,16 'intrepid':4 'jawbreak':2 'manhattan':19 'must':13 'panorama':5 'penthous':20 'woman':8
315	FINDING ANACONDA	A Fateful Tale of a Database Administrator And a Girl who must Battle a Squirrel in New Orleans	2006	1	\N	4	0.99	156	10.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'administr':9 'anaconda':2 'battl':15 'databas':8 'fate':4 'find':1 'girl':12 'must':14 'new':19 'orlean':20 'squirrel':17 'tale':5
316	FIRE WOLVES	A Intrepid Documentary of a Frisbee And a Dog who must Outrace a Lumberjack in Nigeria	2006	1	\N	5	4.99	173	18.99	R	2006-02-15 05:03:42	{Trailers}	'documentari':5 'dog':11 'fire':1 'frisbe':8 'intrepid':4 'lumberjack':16 'must':13 'nigeria':18 'outrac':14 'wolv':2
317	FIREBALL PHILADELPHIA	A Amazing Yarn of a Dentist And a A Shark who must Vanquish a Madman in An Abandoned Mine Shaft	2006	1	\N	4	0.99	148	25.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'abandon':20 'amaz':4 'dentist':8 'firebal':1 'madman':17 'mine':21 'must':14 'philadelphia':2 'shaft':22 'shark':12 'vanquish':15 'yarn':5
318	FIREHOUSE VIETNAM	A Awe-Inspiring Character Study of a Boat And a Boy who must Kill a Pastry Chef in The Sahara Desert	2006	1	\N	7	0.99	103	14.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'awe':5 'awe-inspir':4 'boat':11 'boy':14 'charact':7 'chef':20 'desert':24 'firehous':1 'inspir':6 'kill':17 'must':16 'pastri':19 'sahara':23 'studi':8 'vietnam':2
319	FISH OPUS	A Touching Display of a Feminist And a Girl who must Confront a Astronaut in Australia	2006	1	\N	4	2.99	125	22.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'astronaut':16 'australia':18 'confront':14 'display':5 'feminist':8 'fish':1 'girl':11 'must':13 'opus':2 'touch':4
320	FLAMINGOS CONNECTICUT	A Fast-Paced Reflection of a Composer And a Composer who must Meet a Cat in The Sahara Desert	2006	1	\N	4	4.99	80	28.99	PG-13	2006-02-15 05:03:42	{Trailers}	'cat':18 'compos':10,13 'connecticut':2 'desert':22 'fast':5 'fast-pac':4 'flamingo':1 'meet':16 'must':15 'pace':6 'reflect':7 'sahara':21
321	FLASH WARS	A Astounding Saga of a Moose And a Pastry Chef who must Chase a Student in The Gulf of Mexico	2006	1	\N	3	4.99	123	21.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'astound':4 'chase':15 'chef':12 'flash':1 'gulf':20 'mexico':22 'moos':8 'must':14 'pastri':11 'saga':5 'student':17 'war':2
322	FLATLINERS KILLER	A Taut Display of a Secret Agent And a Waitress who must Sink a Robot in An Abandoned Mine Shaft	2006	1	\N	5	2.99	100	29.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'abandon':20 'agent':9 'display':5 'flatlin':1 'killer':2 'mine':21 'must':14 'robot':17 'secret':8 'shaft':22 'sink':15 'taut':4 'waitress':12
323	FLIGHT LIES	A Stunning Character Study of a Crocodile And a Pioneer who must Pursue a Teacher in New Orleans	2006	1	\N	7	4.99	179	22.99	R	2006-02-15 05:03:42	{Trailers}	'charact':5 'crocodil':9 'flight':1 'lie':2 'must':14 'new':19 'orlean':20 'pioneer':12 'pursu':15 'studi':6 'stun':4 'teacher':17
324	FLINTSTONES HAPPINESS	A Fateful Story of a Husband And a Moose who must Vanquish a Boy in California	2006	1	\N	3	4.99	148	11.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'boy':16 'california':18 'fate':4 'flintston':1 'happi':2 'husband':8 'moos':11 'must':13 'stori':5 'vanquish':14
325	FLOATS GARDEN	A Action-Packed Epistle of a Robot And a Car who must Chase a Boat in Ancient Japan	2006	1	\N	6	2.99	145	29.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'action':5 'action-pack':4 'ancient':20 'boat':18 'car':13 'chase':16 'epistl':7 'float':1 'garden':2 'japan':21 'must':15 'pack':6 'robot':10
326	FLYING HOOK	A Thrilling Display of a Mad Cow And a Dog who must Challenge a Frisbee in Nigeria	2006	1	\N	6	2.99	69	18.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'challeng':15 'cow':9 'display':5 'dog':12 'fli':1 'frisbe':17 'hook':2 'mad':8 'must':14 'nigeria':19 'thrill':4
327	FOOL MOCKINGBIRD	A Lacklusture Tale of a Crocodile And a Composer who must Defeat a Madman in A U-Boat	2006	1	\N	3	4.99	158	24.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'boat':21 'compos':11 'crocodil':8 'defeat':14 'fool':1 'lacklustur':4 'madman':16 'mockingbird':2 'must':13 'tale':5 'u':20 'u-boat':19
328	FOREVER CANDIDATE	A Unbelieveable Panorama of a Technical Writer And a Man who must Pursue a Frisbee in A U-Boat	2006	1	\N	7	2.99	131	28.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'boat':22 'candid':2 'forev':1 'frisbe':17 'man':12 'must':14 'panorama':5 'pursu':15 'technic':8 'u':21 'u-boat':20 'unbeliev':4 'writer':9
329	FORREST SONS	A Thrilling Documentary of a Forensic Psychologist And a Butler who must Defeat a Explorer in A Jet Boat	2006	1	\N	4	2.99	63	15.99	R	2006-02-15 05:03:42	{Commentaries}	'boat':21 'butler':12 'defeat':15 'documentari':5 'explor':17 'forens':8 'forrest':1 'jet':20 'must':14 'psychologist':9 'son':2 'thrill':4
330	FORRESTER COMANCHEROS	A Fateful Tale of a Squirrel And a Forensic Psychologist who must Redeem a Man in Nigeria	2006	1	\N	7	4.99	112	22.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'comanchero':2 'fate':4 'forens':11 'forrest':1 'man':17 'must':14 'nigeria':19 'psychologist':12 'redeem':15 'squirrel':8 'tale':5
331	FORWARD TEMPLE	A Astounding Display of a Forensic Psychologist And a Mad Scientist who must Challenge a Girl in New Orleans	2006	1	\N	6	2.99	90	25.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'astound':4 'challeng':16 'display':5 'forens':8 'forward':1 'girl':18 'mad':12 'must':15 'new':20 'orlean':21 'psychologist':9 'scientist':13 'templ':2
332	FRANKENSTEIN STRANGER	A Insightful Character Study of a Feminist And a Pioneer who must Pursue a Pastry Chef in Nigeria	2006	1	\N	7	0.99	159	16.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'charact':5 'chef':18 'feminist':9 'frankenstein':1 'insight':4 'must':14 'nigeria':20 'pastri':17 'pioneer':12 'pursu':15 'stranger':2 'studi':6
333	FREAKY POCUS	A Fast-Paced Documentary of a Pastry Chef And a Crocodile who must Chase a Squirrel in The Gulf of Mexico	2006	1	\N	7	2.99	126	16.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'chase':17 'chef':11 'crocodil':14 'documentari':7 'fast':5 'fast-pac':4 'freaki':1 'gulf':22 'mexico':24 'must':16 'pace':6 'pastri':10 'pocus':2 'squirrel':19
334	FREDDY STORM	A Intrepid Saga of a Man And a Lumberjack who must Vanquish a Husband in The Outback	2006	1	\N	6	4.99	65	21.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'freddi':1 'husband':16 'intrepid':4 'lumberjack':11 'man':8 'must':13 'outback':19 'saga':5 'storm':2 'vanquish':14
335	FREEDOM CLEOPATRA	A Emotional Reflection of a Dentist And a Mad Cow who must Face a Squirrel in A Baloon	2006	1	\N	5	0.99	133	23.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'baloon':20 'cleopatra':2 'cow':12 'dentist':8 'emot':4 'face':15 'freedom':1 'mad':11 'must':14 'reflect':5 'squirrel':17
336	FRENCH HOLIDAY	A Thrilling Epistle of a Dog And a Feminist who must Kill a Madman in Berlin	2006	1	\N	5	4.99	99	22.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'berlin':18 'dog':8 'epistl':5 'feminist':11 'french':1 'holiday':2 'kill':14 'madman':16 'must':13 'thrill':4
337	FRIDA SLIPPER	A Fateful Story of a Lumberjack And a Car who must Escape a Boat in An Abandoned Mine Shaft	2006	1	\N	6	2.99	73	11.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'abandon':19 'boat':16 'car':11 'escap':14 'fate':4 'frida':1 'lumberjack':8 'mine':20 'must':13 'shaft':21 'slipper':2 'stori':5
338	FRISCO FORREST	A Beautiful Documentary of a Woman And a Pioneer who must Pursue a Mad Scientist in A Shark Tank	2006	1	\N	6	4.99	51	23.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'beauti':4 'documentari':5 'forrest':2 'frisco':1 'mad':16 'must':13 'pioneer':11 'pursu':14 'scientist':17 'shark':20 'tank':21 'woman':8
339	FROGMEN BREAKING	A Unbelieveable Yarn of a Mad Scientist And a Cat who must Chase a Lumberjack in Australia	2006	1	\N	5	0.99	111	17.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'australia':19 'break':2 'cat':12 'chase':15 'frogmen':1 'lumberjack':17 'mad':8 'must':14 'scientist':9 'unbeliev':4 'yarn':5
340	FRONTIER CABIN	A Emotional Story of a Madman And a Waitress who must Battle a Teacher in An Abandoned Fun House	2006	1	\N	6	4.99	183	14.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'abandon':19 'battl':14 'cabin':2 'emot':4 'frontier':1 'fun':20 'hous':21 'madman':8 'must':13 'stori':5 'teacher':16 'waitress':11
341	FROST HEAD	A Amazing Reflection of a Lumberjack And a Cat who must Discover a Husband in A MySQL Convention	2006	1	\N	5	0.99	82	13.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'amaz':4 'cat':11 'convent':20 'discov':14 'frost':1 'head':2 'husband':16 'lumberjack':8 'must':13 'mysql':19 'reflect':5
342	FUGITIVE MAGUIRE	A Taut Epistle of a Feminist And a Sumo Wrestler who must Battle a Crocodile in Australia	2006	1	\N	7	4.99	83	28.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'australia':19 'battl':15 'crocodil':17 'epistl':5 'feminist':8 'fugit':1 'maguir':2 'must':14 'sumo':11 'taut':4 'wrestler':12
343	FULL FLATLINERS	A Beautiful Documentary of a Astronaut And a Moose who must Pursue a Monkey in A Shark Tank	2006	1	\N	6	2.99	94	14.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'astronaut':8 'beauti':4 'documentari':5 'flatlin':2 'full':1 'monkey':16 'moos':11 'must':13 'pursu':14 'shark':19 'tank':20
344	FURY MURDER	A Lacklusture Reflection of a Boat And a Forensic Psychologist who must Fight a Waitress in A Monastery	2006	1	\N	3	0.99	178	28.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'boat':8 'fight':15 'forens':11 'furi':1 'lacklustur':4 'monasteri':20 'murder':2 'must':14 'psychologist':12 'reflect':5 'waitress':17
345	GABLES METROPOLIS	A Fateful Display of a Cat And a Pioneer who must Challenge a Pastry Chef in A Baloon Factory	2006	1	\N	3	0.99	161	17.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'baloon':20 'cat':8 'challeng':14 'chef':17 'display':5 'factori':21 'fate':4 'gabl':1 'metropoli':2 'must':13 'pastri':16 'pioneer':11
346	GALAXY SWEETHEARTS	A Emotional Reflection of a Womanizer And a Pioneer who must Face a Squirrel in Berlin	2006	1	\N	4	4.99	128	13.99	R	2006-02-15 05:03:42	{"Deleted Scenes"}	'berlin':18 'emot':4 'face':14 'galaxi':1 'must':13 'pioneer':11 'reflect':5 'squirrel':16 'sweetheart':2 'woman':8
347	GAMES BOWFINGER	A Astounding Documentary of a Butler And a Explorer who must Challenge a Butler in A Monastery	2006	1	\N	7	4.99	119	17.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'astound':4 'bowfing':2 'butler':8,16 'challeng':14 'documentari':5 'explor':11 'game':1 'monasteri':19 'must':13
348	GANDHI KWAI	A Thoughtful Display of a Mad Scientist And a Secret Agent who must Chase a Boat in Berlin	2006	1	\N	7	0.99	86	9.99	PG-13	2006-02-15 05:03:42	{Trailers}	'agent':13 'berlin':20 'boat':18 'chase':16 'display':5 'gandhi':1 'kwai':2 'mad':8 'must':15 'scientist':9 'secret':12 'thought':4
349	GANGS PRIDE	A Taut Character Study of a Woman And a A Shark who must Confront a Frisbee in Berlin	2006	1	\N	4	2.99	185	27.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'berlin':20 'charact':5 'confront':16 'frisbe':18 'gang':1 'must':15 'pride':2 'shark':13 'studi':6 'taut':4 'woman':9
350	GARDEN ISLAND	A Unbelieveable Character Study of a Womanizer And a Madman who must Reach a Man in The Outback	2006	1	\N	3	4.99	80	21.99	G	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'charact':5 'garden':1 'island':2 'madman':12 'man':17 'must':14 'outback':20 'reach':15 'studi':6 'unbeliev':4 'woman':9
351	GASLIGHT CRUSADE	A Amazing Epistle of a Boy And a Astronaut who must Redeem a Man in The Gulf of Mexico	2006	1	\N	4	2.99	106	10.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'amaz':4 'astronaut':11 'boy':8 'crusad':2 'epistl':5 'gaslight':1 'gulf':19 'man':16 'mexico':21 'must':13 'redeem':14
352	GATHERING CALENDAR	A Intrepid Tale of a Pioneer And a Moose who must Conquer a Frisbee in A MySQL Convention	2006	1	\N	4	0.99	176	22.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'calendar':2 'conquer':14 'convent':20 'frisbe':16 'gather':1 'intrepid':4 'moos':11 'must':13 'mysql':19 'pioneer':8 'tale':5
353	GENTLEMEN STAGE	A Awe-Inspiring Reflection of a Monkey And a Student who must Overcome a Dentist in The First Manned Space Station	2006	1	\N	6	2.99	125	22.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'awe':5 'awe-inspir':4 'dentist':18 'first':21 'gentlemen':1 'inspir':6 'man':22 'monkey':10 'must':15 'overcom':16 'reflect':7 'space':23 'stage':2 'station':24 'student':13
354	GHOST GROUNDHOG	A Brilliant Panorama of a Madman And a Composer who must Succumb a Car in Ancient India	2006	1	\N	6	4.99	85	18.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'ancient':18 'brilliant':4 'car':16 'compos':11 'ghost':1 'groundhog':2 'india':19 'madman':8 'must':13 'panorama':5 'succumb':14
355	GHOSTBUSTERS ELF	A Thoughtful Epistle of a Dog And a Feminist who must Chase a Composer in Berlin	2006	1	\N	7	0.99	101	18.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'berlin':18 'chase':14 'compos':16 'dog':8 'elf':2 'epistl':5 'feminist':11 'ghostbust':1 'must':13 'thought':4
356	GIANT TROOPERS	A Fateful Display of a Feminist And a Monkey who must Vanquish a Monkey in The Canadian Rockies	2006	1	\N	5	2.99	102	10.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'canadian':19 'display':5 'fate':4 'feminist':8 'giant':1 'monkey':11,16 'must':13 'rocki':20 'trooper':2 'vanquish':14
357	GILBERT PELICAN	A Fateful Tale of a Man And a Feminist who must Conquer a Crocodile in A Manhattan Penthouse	2006	1	\N	7	0.99	114	13.99	G	2006-02-15 05:03:42	{Trailers,Commentaries}	'conquer':14 'crocodil':16 'fate':4 'feminist':11 'gilbert':1 'man':8 'manhattan':19 'must':13 'pelican':2 'penthous':20 'tale':5
358	GILMORE BOILED	A Unbelieveable Documentary of a Boat And a Husband who must Succumb a Student in A U-Boat	2006	1	\N	5	0.99	163	29.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'boat':8,21 'boil':2 'documentari':5 'gilmor':1 'husband':11 'must':13 'student':16 'succumb':14 'u':20 'u-boat':19 'unbeliev':4
359	GLADIATOR WESTWARD	A Astounding Reflection of a Squirrel And a Sumo Wrestler who must Sink a Dentist in Ancient Japan	2006	1	\N	6	4.99	173	20.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'ancient':19 'astound':4 'dentist':17 'gladiat':1 'japan':20 'must':14 'reflect':5 'sink':15 'squirrel':8 'sumo':11 'westward':2 'wrestler':12
360	GLASS DYING	A Astounding Drama of a Frisbee And a Astronaut who must Fight a Dog in Ancient Japan	2006	1	\N	4	0.99	103	24.99	G	2006-02-15 05:03:42	{Trailers}	'ancient':18 'astound':4 'astronaut':11 'die':2 'dog':16 'drama':5 'fight':14 'frisbe':8 'glass':1 'japan':19 'must':13
361	GLEAMING JAWBREAKER	A Amazing Display of a Composer And a Forensic Psychologist who must Discover a Car in The Canadian Rockies	2006	1	\N	5	2.99	89	25.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries}	'amaz':4 'canadian':20 'car':17 'compos':8 'discov':15 'display':5 'forens':11 'gleam':1 'jawbreak':2 'must':14 'psychologist':12 'rocki':21
362	GLORY TRACY	A Amazing Saga of a Woman And a Womanizer who must Discover a Cat in The First Manned Space Station	2006	1	\N	7	2.99	115	13.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'amaz':4 'cat':16 'discov':14 'first':19 'glori':1 'man':20 'must':13 'saga':5 'space':21 'station':22 'traci':2 'woman':8,11
363	GO PURPLE	A Fast-Paced Display of a Car And a Database Administrator who must Battle a Woman in A Baloon	2006	1	\N	3	0.99	54	12.99	R	2006-02-15 05:03:42	{Trailers}	'administr':14 'baloon':22 'battl':17 'car':10 'databas':13 'display':7 'fast':5 'fast-pac':4 'go':1 'must':16 'pace':6 'purpl':2 'woman':19
364	GODFATHER DIARY	A Stunning Saga of a Lumberjack And a Squirrel who must Chase a Car in The Outback	2006	1	\N	3	2.99	73	14.99	NC-17	2006-02-15 05:03:42	{Trailers}	'car':16 'chase':14 'diari':2 'godfath':1 'lumberjack':8 'must':13 'outback':19 'saga':5 'squirrel':11 'stun':4
365	GOLD RIVER	A Taut Documentary of a Database Administrator And a Waitress who must Reach a Mad Scientist in A Baloon Factory	2006	1	\N	4	4.99	154	21.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'administr':9 'baloon':21 'databas':8 'documentari':5 'factori':22 'gold':1 'mad':17 'must':14 'reach':15 'river':2 'scientist':18 'taut':4 'waitress':12
366	GOLDFINGER SENSIBILITY	A Insightful Drama of a Mad Scientist And a Hunter who must Defeat a Pastry Chef in New Orleans	2006	1	\N	3	0.99	93	29.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'chef':18 'defeat':15 'drama':5 'goldfing':1 'hunter':12 'insight':4 'mad':8 'must':14 'new':20 'orlean':21 'pastri':17 'scientist':9 'sensibl':2
367	GOLDMINE TYCOON	A Brilliant Epistle of a Composer And a Frisbee who must Conquer a Husband in The Outback	2006	1	\N	6	0.99	153	20.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'brilliant':4 'compos':8 'conquer':14 'epistl':5 'frisbe':11 'goldmin':1 'husband':16 'must':13 'outback':19 'tycoon':2
368	GONE TROUBLE	A Insightful Character Study of a Mad Cow And a Forensic Psychologist who must Conquer a A Shark in A Manhattan Penthouse	2006	1	\N	7	2.99	84	20.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'charact':5 'conquer':17 'cow':10 'forens':13 'gone':1 'insight':4 'mad':9 'manhattan':23 'must':16 'penthous':24 'psychologist':14 'shark':20 'studi':6 'troubl':2
369	GOODFELLAS SALUTE	A Unbelieveable Tale of a Dog And a Explorer who must Sink a Mad Cow in A Baloon Factory	2006	1	\N	4	4.99	56	22.99	PG	2006-02-15 05:03:42	{"Deleted Scenes"}	'baloon':20 'cow':17 'dog':8 'explor':11 'factori':21 'goodfella':1 'mad':16 'must':13 'salut':2 'sink':14 'tale':5 'unbeliev':4
370	GORGEOUS BINGO	A Action-Packed Display of a Sumo Wrestler And a Car who must Overcome a Waitress in A Baloon Factory	2006	1	\N	4	2.99	108	26.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'action':5 'action-pack':4 'baloon':22 'bingo':2 'car':14 'display':7 'factori':23 'gorgeous':1 'must':16 'overcom':17 'pack':6 'sumo':10 'waitress':19 'wrestler':11
371	GOSFORD DONNIE	A Epic Panorama of a Mad Scientist And a Monkey who must Redeem a Secret Agent in Berlin	2006	1	\N	5	4.99	129	17.99	G	2006-02-15 05:03:42	{Commentaries}	'agent':18 'berlin':20 'donni':2 'epic':4 'gosford':1 'mad':8 'monkey':12 'must':14 'panorama':5 'redeem':15 'scientist':9 'secret':17
372	GRACELAND DYNAMITE	A Taut Display of a Cat And a Girl who must Overcome a Database Administrator in New Orleans	2006	1	\N	5	4.99	140	26.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'administr':17 'cat':8 'databas':16 'display':5 'dynamit':2 'girl':11 'graceland':1 'must':13 'new':19 'orlean':20 'overcom':14 'taut':4
373	GRADUATE LORD	A Lacklusture Epistle of a Girl And a A Shark who must Meet a Mad Scientist in Ancient China	2006	1	\N	7	2.99	156	14.99	G	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'ancient':20 'china':21 'epistl':5 'girl':8 'graduat':1 'lacklustur':4 'lord':2 'mad':17 'meet':15 'must':14 'scientist':18 'shark':12
374	GRAFFITI LOVE	A Unbelieveable Epistle of a Sumo Wrestler And a Hunter who must Build a Composer in Berlin	2006	1	\N	3	0.99	117	29.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'berlin':19 'build':15 'compos':17 'epistl':5 'graffiti':1 'hunter':12 'love':2 'must':14 'sumo':8 'unbeliev':4 'wrestler':9
375	GRAIL FRANKENSTEIN	A Unbelieveable Saga of a Teacher And a Monkey who must Fight a Girl in An Abandoned Mine Shaft	2006	1	\N	4	2.99	85	17.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':19 'fight':14 'frankenstein':2 'girl':16 'grail':1 'mine':20 'monkey':11 'must':13 'saga':5 'shaft':21 'teacher':8 'unbeliev':4
376	GRAPES FURY	A Boring Yarn of a Mad Cow And a Sumo Wrestler who must Meet a Robot in Australia	2006	1	\N	4	0.99	155	20.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'australia':20 'bore':4 'cow':9 'furi':2 'grape':1 'mad':8 'meet':16 'must':15 'robot':18 'sumo':12 'wrestler':13 'yarn':5
377	GREASE YOUTH	A Emotional Panorama of a Secret Agent And a Waitress who must Escape a Composer in Soviet Georgia	2006	1	\N	7	0.99	135	20.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'agent':9 'compos':17 'emot':4 'escap':15 'georgia':20 'greas':1 'must':14 'panorama':5 'secret':8 'soviet':19 'waitress':12 'youth':2
378	GREATEST NORTH	A Astounding Character Study of a Secret Agent And a Robot who must Build a A Shark in Berlin	2006	1	\N	5	2.99	93	24.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'agent':10 'astound':4 'berlin':21 'build':16 'charact':5 'greatest':1 'must':15 'north':2 'robot':13 'secret':9 'shark':19 'studi':6
379	GREEDY ROOTS	A Amazing Reflection of a A Shark And a Butler who must Chase a Hunter in The Canadian Rockies	2006	1	\N	7	0.99	166	14.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'amaz':4 'butler':12 'canadian':20 'chase':15 'greedi':1 'hunter':17 'must':14 'reflect':5 'rocki':21 'root':2 'shark':9
380	GREEK EVERYONE	A Stunning Display of a Butler And a Teacher who must Confront a A Shark in The First Manned Space Station	2006	1	\N	7	2.99	176	11.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'butler':8 'confront':14 'display':5 'everyon':2 'first':20 'greek':1 'man':21 'must':13 'shark':17 'space':22 'station':23 'stun':4 'teacher':11
381	GRINCH MASSAGE	A Intrepid Display of a Madman And a Feminist who must Pursue a Pioneer in The First Manned Space Station	2006	1	\N	7	4.99	150	25.99	R	2006-02-15 05:03:42	{Trailers}	'display':5 'feminist':11 'first':19 'grinch':1 'intrepid':4 'madman':8 'man':20 'massag':2 'must':13 'pioneer':16 'pursu':14 'space':21 'station':22
382	GRIT CLOCKWORK	A Thoughtful Display of a Dentist And a Squirrel who must Confront a Lumberjack in A Shark Tank	2006	1	\N	3	0.99	137	21.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'clockwork':2 'confront':14 'dentist':8 'display':5 'grit':1 'lumberjack':16 'must':13 'shark':19 'squirrel':11 'tank':20 'thought':4
383	GROOVE FICTION	A Unbelieveable Reflection of a Moose And a A Shark who must Defeat a Lumberjack in An Abandoned Mine Shaft	2006	1	\N	6	0.99	111	13.99	NC-17	2006-02-15 05:03:42	{"Behind the Scenes"}	'abandon':20 'defeat':15 'fiction':2 'groov':1 'lumberjack':17 'mine':21 'moos':8 'must':14 'reflect':5 'shaft':22 'shark':12 'unbeliev':4
384	GROSSE WONDERFUL	A Epic Drama of a Cat And a Explorer who must Redeem a Moose in Australia	2006	1	\N	5	4.99	49	19.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'australia':18 'cat':8 'drama':5 'epic':4 'explor':11 'gross':1 'moos':16 'must':13 'redeem':14 'wonder':2
385	GROUNDHOG UNCUT	A Brilliant Panorama of a Astronaut And a Technical Writer who must Discover a Butler in A Manhattan Penthouse	2006	1	\N	6	4.99	139	26.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'astronaut':8 'brilliant':4 'butler':17 'discov':15 'groundhog':1 'manhattan':20 'must':14 'panorama':5 'penthous':21 'technic':11 'uncut':2 'writer':12
386	GUMP DATE	A Intrepid Yarn of a Explorer And a Student who must Kill a Husband in An Abandoned Mine Shaft	2006	1	\N	3	4.99	53	12.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes"}	'abandon':19 'date':2 'explor':8 'gump':1 'husband':16 'intrepid':4 'kill':14 'mine':20 'must':13 'shaft':21 'student':11 'yarn':5
387	GUN BONNIE	A Boring Display of a Sumo Wrestler And a Husband who must Build a Waitress in The Gulf of Mexico	2006	1	\N	7	0.99	100	27.99	G	2006-02-15 05:03:42	{"Behind the Scenes"}	'bonni':2 'bore':4 'build':15 'display':5 'gulf':20 'gun':1 'husband':12 'mexico':22 'must':14 'sumo':8 'waitress':17 'wrestler':9
388	GUNFIGHT MOON	A Epic Reflection of a Pastry Chef And a Explorer who must Reach a Dentist in The Sahara Desert	2006	1	\N	5	0.99	70	16.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'chef':9 'dentist':17 'desert':21 'epic':4 'explor':12 'gunfight':1 'moon':2 'must':14 'pastri':8 'reach':15 'reflect':5 'sahara':20
389	GUNFIGHTER MUSSOLINI	A Touching Saga of a Robot And a Boy who must Kill a Man in Ancient Japan	2006	1	\N	3	2.99	127	9.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'ancient':18 'boy':11 'gunfight':1 'japan':19 'kill':14 'man':16 'mussolini':2 'must':13 'robot':8 'saga':5 'touch':4
390	GUYS FALCON	A Boring Story of a Woman And a Feminist who must Redeem a Squirrel in A U-Boat	2006	1	\N	4	4.99	84	20.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'boat':21 'bore':4 'falcon':2 'feminist':11 'guy':1 'must':13 'redeem':14 'squirrel':16 'stori':5 'u':20 'u-boat':19 'woman':8
391	HALF OUTFIELD	A Epic Epistle of a Database Administrator And a Crocodile who must Face a Madman in A Jet Boat	2006	1	\N	6	2.99	146	25.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'administr':9 'boat':21 'crocodil':12 'databas':8 'epic':4 'epistl':5 'face':15 'half':1 'jet':20 'madman':17 'must':14 'outfield':2
392	HALL CASSIDY	A Beautiful Panorama of a Pastry Chef And a A Shark who must Battle a Pioneer in Soviet Georgia	2006	1	\N	5	4.99	51	13.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'battl':16 'beauti':4 'cassidi':2 'chef':9 'georgia':21 'hall':1 'must':15 'panorama':5 'pastri':8 'pioneer':18 'shark':13 'soviet':20
393	HALLOWEEN NUTS	A Amazing Panorama of a Forensic Psychologist And a Technical Writer who must Fight a Dentist in A U-Boat	2006	1	\N	6	2.99	47	19.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'amaz':4 'boat':23 'dentist':18 'fight':16 'forens':8 'halloween':1 'must':15 'nut':2 'panorama':5 'psychologist':9 'technic':12 'u':22 'u-boat':21 'writer':13
394	HAMLET WISDOM	A Touching Reflection of a Man And a Man who must Sink a Robot in The Outback	2006	1	\N	7	2.99	146	21.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'hamlet':1 'man':8,11 'must':13 'outback':19 'reflect':5 'robot':16 'sink':14 'touch':4 'wisdom':2
395	HANDICAP BOONDOCK	A Beautiful Display of a Pioneer And a Squirrel who must Vanquish a Sumo Wrestler in Soviet Georgia	2006	1	\N	4	0.99	108	28.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'beauti':4 'boondock':2 'display':5 'georgia':20 'handicap':1 'must':13 'pioneer':8 'soviet':19 'squirrel':11 'sumo':16 'vanquish':14 'wrestler':17
396	HANGING DEEP	A Action-Packed Yarn of a Boat And a Crocodile who must Build a Monkey in Berlin	2006	1	\N	5	4.99	62	18.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'action':5 'action-pack':4 'berlin':20 'boat':10 'build':16 'crocodil':13 'deep':2 'hang':1 'monkey':18 'must':15 'pack':6 'yarn':7
397	HANKY OCTOBER	A Boring Epistle of a Database Administrator And a Explorer who must Pursue a Madman in Soviet Georgia	2006	1	\N	5	2.99	107	26.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'administr':9 'bore':4 'databas':8 'epistl':5 'explor':12 'georgia':20 'hanki':1 'madman':17 'must':14 'octob':2 'pursu':15 'soviet':19
398	HANOVER GALAXY	A Stunning Reflection of a Girl And a Secret Agent who must Succumb a Boy in A MySQL Convention	2006	1	\N	5	4.99	47	21.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'agent':12 'boy':17 'convent':21 'galaxi':2 'girl':8 'hanov':1 'must':14 'mysql':20 'reflect':5 'secret':11 'stun':4 'succumb':15
399	HAPPINESS UNITED	A Action-Packed Panorama of a Husband And a Feminist who must Meet a Forensic Psychologist in Ancient Japan	2006	1	\N	6	2.99	100	23.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'action':5 'action-pack':4 'ancient':21 'feminist':13 'forens':18 'happi':1 'husband':10 'japan':22 'meet':16 'must':15 'pack':6 'panorama':7 'psychologist':19 'unit':2
400	HARDLY ROBBERS	A Emotional Character Study of a Hunter And a Car who must Kill a Woman in Berlin	2006	1	\N	7	2.99	72	15.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'berlin':19 'car':12 'charact':5 'emot':4 'hard':1 'hunter':9 'kill':15 'must':14 'robber':2 'studi':6 'woman':17
401	HAROLD FRENCH	A Stunning Saga of a Sumo Wrestler And a Student who must Outrace a Moose in The Sahara Desert	2006	1	\N	6	0.99	168	10.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'desert':21 'french':2 'harold':1 'moos':17 'must':14 'outrac':15 'saga':5 'sahara':20 'student':12 'stun':4 'sumo':8 'wrestler':9
402	HARPER DYING	A Awe-Inspiring Reflection of a Woman And a Cat who must Confront a Feminist in The Sahara Desert	2006	1	\N	3	0.99	52	15.99	G	2006-02-15 05:03:42	{Trailers}	'awe':5 'awe-inspir':4 'cat':13 'confront':16 'desert':22 'die':2 'feminist':18 'harper':1 'inspir':6 'must':15 'reflect':7 'sahara':21 'woman':10
403	HARRY IDAHO	A Taut Yarn of a Technical Writer And a Feminist who must Outrace a Dog in California	2006	1	\N	5	4.99	121	18.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'california':19 'dog':17 'feminist':12 'harri':1 'idaho':2 'must':14 'outrac':15 'taut':4 'technic':8 'writer':9 'yarn':5
404	HATE HANDICAP	A Intrepid Reflection of a Mad Scientist And a Pioneer who must Overcome a Hunter in The First Manned Space Station	2006	1	\N	4	0.99	107	26.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'first':20 'handicap':2 'hate':1 'hunter':17 'intrepid':4 'mad':8 'man':21 'must':14 'overcom':15 'pioneer':12 'reflect':5 'scientist':9 'space':22 'station':23
405	HAUNTED ANTITRUST	A Amazing Saga of a Man And a Dentist who must Reach a Technical Writer in Ancient India	2006	1	\N	6	4.99	76	13.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'amaz':4 'ancient':19 'antitrust':2 'dentist':11 'haunt':1 'india':20 'man':8 'must':13 'reach':14 'saga':5 'technic':16 'writer':17
406	HAUNTING PIANIST	A Fast-Paced Story of a Database Administrator And a Composer who must Defeat a Squirrel in An Abandoned Amusement Park	2006	1	\N	5	0.99	181	22.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'abandon':22 'administr':11 'amus':23 'compos':14 'databas':10 'defeat':17 'fast':5 'fast-pac':4 'haunt':1 'must':16 'pace':6 'park':24 'pianist':2 'squirrel':19 'stori':7
407	HAWK CHILL	A Action-Packed Drama of a Mad Scientist And a Composer who must Outgun a Car in Australia	2006	1	\N	5	0.99	47	12.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'action':5 'action-pack':4 'australia':21 'car':19 'chill':2 'compos':14 'drama':7 'hawk':1 'mad':10 'must':16 'outgun':17 'pack':6 'scientist':11
408	HEAD STRANGER	A Thoughtful Saga of a Hunter And a Crocodile who must Confront a Dog in The Gulf of Mexico	2006	1	\N	4	4.99	69	28.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'confront':14 'crocodil':11 'dog':16 'gulf':19 'head':1 'hunter':8 'mexico':21 'must':13 'saga':5 'stranger':2 'thought':4
409	HEARTBREAKERS BRIGHT	A Awe-Inspiring Documentary of a A Shark And a Dentist who must Outrace a Pastry Chef in The Canadian Rockies	2006	1	\N	3	4.99	59	9.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'awe':5 'awe-inspir':4 'bright':2 'canadian':23 'chef':20 'dentist':14 'documentari':7 'heartbreak':1 'inspir':6 'must':16 'outrac':17 'pastri':19 'rocki':24 'shark':11
410	HEAVEN FREEDOM	A Intrepid Story of a Butler And a Car who must Vanquish a Man in New Orleans	2006	1	\N	7	2.99	48	19.99	PG	2006-02-15 05:03:42	{Commentaries}	'butler':8 'car':11 'freedom':2 'heaven':1 'intrepid':4 'man':16 'must':13 'new':18 'orlean':19 'stori':5 'vanquish':14
411	HEAVENLY GUN	A Beautiful Yarn of a Forensic Psychologist And a Frisbee who must Battle a Moose in A Jet Boat	2006	1	\N	5	4.99	49	13.99	NC-17	2006-02-15 05:03:42	{"Behind the Scenes"}	'battl':15 'beauti':4 'boat':21 'forens':8 'frisbe':12 'gun':2 'heaven':1 'jet':20 'moos':17 'must':14 'psychologist':9 'yarn':5
412	HEAVYWEIGHTS BEAST	A Unbelieveable Story of a Composer And a Dog who must Overcome a Womanizer in An Abandoned Amusement Park	2006	1	\N	6	4.99	102	25.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'abandon':19 'amus':20 'beast':2 'compos':8 'dog':11 'heavyweight':1 'must':13 'overcom':14 'park':21 'stori':5 'unbeliev':4 'woman':16
413	HEDWIG ALTER	A Action-Packed Yarn of a Womanizer And a Lumberjack who must Chase a Sumo Wrestler in A Monastery	2006	1	\N	7	2.99	169	16.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'action':5 'action-pack':4 'alter':2 'chase':16 'hedwig':1 'lumberjack':13 'monasteri':22 'must':15 'pack':6 'sumo':18 'woman':10 'wrestler':19 'yarn':7
414	HELLFIGHTERS SIERRA	A Taut Reflection of a A Shark And a Dentist who must Battle a Boat in Soviet Georgia	2006	1	\N	3	2.99	75	23.99	PG	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'battl':15 'boat':17 'dentist':12 'georgia':20 'hellfight':1 'must':14 'reflect':5 'shark':9 'sierra':2 'soviet':19 'taut':4
415	HIGH ENCINO	A Fateful Saga of a Waitress And a Hunter who must Outrace a Sumo Wrestler in Australia	2006	1	\N	3	2.99	84	23.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'australia':19 'encino':2 'fate':4 'high':1 'hunter':11 'must':13 'outrac':14 'saga':5 'sumo':16 'waitress':8 'wrestler':17
416	HIGHBALL POTTER	A Action-Packed Saga of a Husband And a Dog who must Redeem a Database Administrator in The Sahara Desert	2006	1	\N	6	0.99	110	10.99	R	2006-02-15 05:03:42	{"Deleted Scenes"}	'action':5 'action-pack':4 'administr':19 'databas':18 'desert':23 'dog':13 'highbal':1 'husband':10 'must':15 'pack':6 'potter':2 'redeem':16 'saga':7 'sahara':22
417	HILLS NEIGHBORS	A Epic Display of a Hunter And a Feminist who must Sink a Car in A U-Boat	2006	1	\N	5	0.99	93	29.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'boat':21 'car':16 'display':5 'epic':4 'feminist':11 'hill':1 'hunter':8 'must':13 'neighbor':2 'sink':14 'u':20 'u-boat':19
418	HOBBIT ALIEN	A Emotional Drama of a Husband And a Girl who must Outgun a Composer in The First Manned Space Station	2006	1	\N	5	0.99	157	27.99	PG-13	2006-02-15 05:03:42	{Commentaries}	'alien':2 'compos':16 'drama':5 'emot':4 'first':19 'girl':11 'hobbit':1 'husband':8 'man':20 'must':13 'outgun':14 'space':21 'station':22
419	HOCUS FRIDA	A Awe-Inspiring Tale of a Girl And a Madman who must Outgun a Student in A Shark Tank	2006	1	\N	4	2.99	141	19.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'awe':5 'awe-inspir':4 'frida':2 'girl':10 'hocus':1 'inspir':6 'madman':13 'must':15 'outgun':16 'shark':21 'student':18 'tale':7 'tank':22
420	HOLES BRANNIGAN	A Fast-Paced Reflection of a Technical Writer And a Student who must Fight a Boy in The Canadian Rockies	2006	1	\N	7	4.99	128	27.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'boy':19 'brannigan':2 'canadian':22 'fast':5 'fast-pac':4 'fight':17 'hole':1 'must':16 'pace':6 'reflect':7 'rocki':23 'student':14 'technic':10 'writer':11
421	HOLIDAY GAMES	A Insightful Reflection of a Waitress And a Madman who must Pursue a Boy in Ancient Japan	2006	1	\N	7	4.99	78	10.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'ancient':18 'boy':16 'game':2 'holiday':1 'insight':4 'japan':19 'madman':11 'must':13 'pursu':14 'reflect':5 'waitress':8
422	HOLLOW JEOPARDY	A Beautiful Character Study of a Robot And a Astronaut who must Overcome a Boat in A Monastery	2006	1	\N	7	4.99	136	25.99	NC-17	2006-02-15 05:03:42	{"Behind the Scenes"}	'astronaut':12 'beauti':4 'boat':17 'charact':5 'hollow':1 'jeopardi':2 'monasteri':20 'must':14 'overcom':15 'robot':9 'studi':6
423	HOLLYWOOD ANONYMOUS	A Fast-Paced Epistle of a Boy And a Explorer who must Escape a Dog in A U-Boat	2006	1	\N	7	0.99	69	29.99	PG	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'anonym':2 'boat':23 'boy':10 'dog':18 'epistl':7 'escap':16 'explor':13 'fast':5 'fast-pac':4 'hollywood':1 'must':15 'pace':6 'u':22 'u-boat':21
424	HOLOCAUST HIGHBALL	A Awe-Inspiring Yarn of a Composer And a Man who must Find a Robot in Soviet Georgia	2006	1	\N	6	0.99	149	12.99	R	2006-02-15 05:03:42	{"Deleted Scenes"}	'awe':5 'awe-inspir':4 'compos':10 'find':16 'georgia':21 'highbal':2 'holocaust':1 'inspir':6 'man':13 'must':15 'robot':18 'soviet':20 'yarn':7
425	HOLY TADPOLE	A Action-Packed Display of a Feminist And a Pioneer who must Pursue a Dog in A Baloon Factory	2006	1	\N	6	0.99	88	20.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'action':5 'action-pack':4 'baloon':21 'display':7 'dog':18 'factori':22 'feminist':10 'holi':1 'must':15 'pack':6 'pioneer':13 'pursu':16 'tadpol':2
426	HOME PITY	A Touching Panorama of a Man And a Secret Agent who must Challenge a Teacher in A MySQL Convention	2006	1	\N	7	4.99	185	15.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'agent':12 'challeng':15 'convent':21 'home':1 'man':8 'must':14 'mysql':20 'panorama':5 'piti':2 'secret':11 'teacher':17 'touch':4
427	HOMEWARD CIDER	A Taut Reflection of a Astronaut And a Squirrel who must Fight a Squirrel in A Manhattan Penthouse	2006	1	\N	5	0.99	103	19.99	R	2006-02-15 05:03:42	{Trailers}	'astronaut':8 'cider':2 'fight':14 'homeward':1 'manhattan':19 'must':13 'penthous':20 'reflect':5 'squirrel':11,16 'taut':4
428	HOMICIDE PEACH	A Astounding Documentary of a Hunter And a Boy who must Confront a Boy in A MySQL Convention	2006	1	\N	6	2.99	141	21.99	PG-13	2006-02-15 05:03:42	{Commentaries}	'astound':4 'boy':11,16 'confront':14 'convent':20 'documentari':5 'homicid':1 'hunter':8 'must':13 'mysql':19 'peach':2
429	HONEY TIES	A Taut Story of a Waitress And a Crocodile who must Outrace a Lumberjack in A Shark Tank	2006	1	\N	3	0.99	84	29.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'crocodil':11 'honey':1 'lumberjack':16 'must':13 'outrac':14 'shark':19 'stori':5 'tank':20 'taut':4 'tie':2 'waitress':8
430	HOOK CHARIOTS	A Insightful Story of a Boy And a Dog who must Redeem a Boy in Australia	2006	1	\N	7	0.99	49	23.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'australia':18 'boy':8,16 'chariot':2 'dog':11 'hook':1 'insight':4 'must':13 'redeem':14 'stori':5
431	HOOSIERS BIRDCAGE	A Astounding Display of a Explorer And a Boat who must Vanquish a Car in The First Manned Space Station	2006	1	\N	3	2.99	176	12.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'astound':4 'birdcag':2 'boat':11 'car':16 'display':5 'explor':8 'first':19 'hoosier':1 'man':20 'must':13 'space':21 'station':22 'vanquish':14
432	HOPE TOOTSIE	A Amazing Documentary of a Student And a Sumo Wrestler who must Outgun a A Shark in A Shark Tank	2006	1	\N	4	2.99	139	22.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'amaz':4 'documentari':5 'hope':1 'must':14 'outgun':15 'shark':18,21 'student':8 'sumo':11 'tank':22 'tootsi':2 'wrestler':12
433	HORN WORKING	A Stunning Display of a Mad Scientist And a Technical Writer who must Succumb a Monkey in A Shark Tank	2006	1	\N	4	2.99	95	23.99	PG	2006-02-15 05:03:42	{Trailers}	'display':5 'horn':1 'mad':8 'monkey':18 'must':15 'scientist':9 'shark':21 'stun':4 'succumb':16 'tank':22 'technic':12 'work':2 'writer':13
434	HORROR REIGN	A Touching Documentary of a A Shark And a Car who must Build a Husband in Nigeria	2006	1	\N	3	0.99	139	25.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'build':15 'car':12 'documentari':5 'horror':1 'husband':17 'must':14 'nigeria':19 'reign':2 'shark':9 'touch':4
435	HOTEL HAPPINESS	A Thrilling Yarn of a Pastry Chef And a A Shark who must Challenge a Mad Scientist in The Outback	2006	1	\N	6	4.99	181	28.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'challeng':16 'chef':9 'happi':2 'hotel':1 'mad':18 'must':15 'outback':22 'pastri':8 'scientist':19 'shark':13 'thrill':4 'yarn':5
436	HOURS RAGE	A Fateful Story of a Explorer And a Feminist who must Meet a Technical Writer in Soviet Georgia	2006	1	\N	4	0.99	122	14.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'explor':8 'fate':4 'feminist':11 'georgia':20 'hour':1 'meet':14 'must':13 'rage':2 'soviet':19 'stori':5 'technic':16 'writer':17
437	HOUSE DYNAMITE	A Taut Story of a Pioneer And a Squirrel who must Battle a Student in Soviet Georgia	2006	1	\N	7	2.99	109	13.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'battl':14 'dynamit':2 'georgia':19 'hous':1 'must':13 'pioneer':8 'soviet':18 'squirrel':11 'stori':5 'student':16 'taut':4
438	HUMAN GRAFFITI	A Beautiful Reflection of a Womanizer And a Sumo Wrestler who must Chase a Database Administrator in The Gulf of Mexico	2006	1	\N	3	2.99	68	22.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'administr':18 'beauti':4 'chase':15 'databas':17 'graffiti':2 'gulf':21 'human':1 'mexico':23 'must':14 'reflect':5 'sumo':11 'woman':8 'wrestler':12
439	HUNCHBACK IMPOSSIBLE	A Touching Yarn of a Frisbee And a Dentist who must Fight a Composer in Ancient Japan	2006	1	\N	4	4.99	151	28.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'ancient':18 'compos':16 'dentist':11 'fight':14 'frisbe':8 'hunchback':1 'imposs':2 'japan':19 'must':13 'touch':4 'yarn':5
440	HUNGER ROOF	A Unbelieveable Yarn of a Student And a Database Administrator who must Outgun a Husband in An Abandoned Mine Shaft	2006	1	\N	6	0.99	105	21.99	G	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'abandon':20 'administr':12 'databas':11 'hunger':1 'husband':17 'mine':21 'must':14 'outgun':15 'roof':2 'shaft':22 'student':8 'unbeliev':4 'yarn':5
441	HUNTER ALTER	A Emotional Drama of a Mad Cow And a Boat who must Redeem a Secret Agent in A Shark Tank	2006	1	\N	5	2.99	125	21.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'agent':18 'alter':2 'boat':12 'cow':9 'drama':5 'emot':4 'hunter':1 'mad':8 'must':14 'redeem':15 'secret':17 'shark':21 'tank':22
442	HUNTING MUSKETEERS	A Thrilling Reflection of a Pioneer And a Dentist who must Outrace a Womanizer in An Abandoned Mine Shaft	2006	1	\N	6	2.99	65	24.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'abandon':19 'dentist':11 'hunt':1 'mine':20 'musket':2 'must':13 'outrac':14 'pioneer':8 'reflect':5 'shaft':21 'thrill':4 'woman':16
443	HURRICANE AFFAIR	A Lacklusture Epistle of a Database Administrator And a Woman who must Meet a Hunter in An Abandoned Mine Shaft	2006	1	\N	6	2.99	49	11.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'abandon':20 'administr':9 'affair':2 'databas':8 'epistl':5 'hunter':17 'hurrican':1 'lacklustur':4 'meet':15 'mine':21 'must':14 'shaft':22 'woman':12
444	HUSTLER PARTY	A Emotional Reflection of a Sumo Wrestler And a Monkey who must Conquer a Robot in The Sahara Desert	2006	1	\N	3	4.99	83	22.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'conquer':15 'desert':21 'emot':4 'hustler':1 'monkey':12 'must':14 'parti':2 'reflect':5 'robot':17 'sahara':20 'sumo':8 'wrestler':9
445	HYDE DOCTOR	A Fanciful Documentary of a Boy And a Woman who must Redeem a Womanizer in A Jet Boat	2006	1	\N	5	2.99	100	11.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'boat':20 'boy':8 'doctor':2 'documentari':5 'fanci':4 'hyde':1 'jet':19 'must':13 'redeem':14 'woman':11,16
446	HYSTERICAL GRAIL	A Amazing Saga of a Madman And a Dentist who must Build a Car in A Manhattan Penthouse	2006	1	\N	5	4.99	150	19.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'amaz':4 'build':14 'car':16 'dentist':11 'grail':2 'hyster':1 'madman':8 'manhattan':19 'must':13 'penthous':20 'saga':5
447	ICE CROSSING	A Fast-Paced Tale of a Butler And a Moose who must Overcome a Pioneer in A Manhattan Penthouse	2006	1	\N	5	2.99	131	28.99	R	2006-02-15 05:03:42	{"Deleted Scenes"}	'butler':10 'cross':2 'fast':5 'fast-pac':4 'ice':1 'manhattan':21 'moos':13 'must':15 'overcom':16 'pace':6 'penthous':22 'pioneer':18 'tale':7
448	IDAHO LOVE	A Fast-Paced Drama of a Student And a Crocodile who must Meet a Database Administrator in The Outback	2006	1	\N	3	2.99	172	25.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'administr':19 'crocodil':13 'databas':18 'drama':7 'fast':5 'fast-pac':4 'idaho':1 'love':2 'meet':16 'must':15 'outback':22 'pace':6 'student':10
449	IDENTITY LOVER	A Boring Tale of a Composer And a Mad Cow who must Defeat a Car in The Outback	2006	1	\N	4	2.99	119	12.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'bore':4 'car':17 'compos':8 'cow':12 'defeat':15 'ident':1 'lover':2 'mad':11 'must':14 'outback':20 'tale':5
450	IDOLS SNATCHERS	A Insightful Drama of a Car And a Composer who must Fight a Man in A Monastery	2006	1	\N	5	2.99	84	29.99	NC-17	2006-02-15 05:03:42	{Trailers}	'car':8 'compos':11 'drama':5 'fight':14 'idol':1 'insight':4 'man':16 'monasteri':19 'must':13 'snatcher':2
451	IGBY MAKER	A Epic Documentary of a Hunter And a Dog who must Outgun a Dog in A Baloon Factory	2006	1	\N	7	4.99	160	12.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'baloon':19 'documentari':5 'dog':11,16 'epic':4 'factori':20 'hunter':8 'igbi':1 'maker':2 'must':13 'outgun':14
452	ILLUSION AMELIE	A Emotional Epistle of a Boat And a Mad Scientist who must Outrace a Robot in An Abandoned Mine Shaft	2006	1	\N	4	0.99	122	15.99	R	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'abandon':20 'ameli':2 'boat':8 'emot':4 'epistl':5 'illus':1 'mad':11 'mine':21 'must':14 'outrac':15 'robot':17 'scientist':12 'shaft':22
453	IMAGE PRINCESS	A Lacklusture Panorama of a Secret Agent And a Crocodile who must Discover a Madman in The Canadian Rockies	2006	1	\N	3	2.99	178	17.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'agent':9 'canadian':20 'crocodil':12 'discov':15 'imag':1 'lacklustur':4 'madman':17 'must':14 'panorama':5 'princess':2 'rocki':21 'secret':8
454	IMPACT ALADDIN	A Epic Character Study of a Frisbee And a Moose who must Outgun a Technical Writer in A Shark Tank	2006	1	\N	6	0.99	180	20.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'aladdin':2 'charact':5 'epic':4 'frisbe':9 'impact':1 'moos':12 'must':14 'outgun':15 'shark':21 'studi':6 'tank':22 'technic':17 'writer':18
455	IMPOSSIBLE PREJUDICE	A Awe-Inspiring Yarn of a Monkey And a Hunter who must Chase a Teacher in Ancient China	2006	1	\N	7	4.99	103	11.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes"}	'ancient':20 'awe':5 'awe-inspir':4 'chase':16 'china':21 'hunter':13 'imposs':1 'inspir':6 'monkey':10 'must':15 'prejudic':2 'teacher':18 'yarn':7
456	INCH JET	A Fateful Saga of a Womanizer And a Student who must Defeat a Butler in A Monastery	2006	1	\N	6	4.99	167	18.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes"}	'butler':16 'defeat':14 'fate':4 'inch':1 'jet':2 'monasteri':19 'must':13 'saga':5 'student':11 'woman':8
457	INDEPENDENCE HOTEL	A Thrilling Tale of a Technical Writer And a Boy who must Face a Pioneer in A Monastery	2006	1	\N	5	0.99	157	21.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'boy':12 'face':15 'hotel':2 'independ':1 'monasteri':20 'must':14 'pioneer':17 'tale':5 'technic':8 'thrill':4 'writer':9
753	RUSH GOODFELLAS	A Emotional Display of a Man And a Dentist who must Challenge a Squirrel in Australia	2006	1	\N	3	0.99	48	20.99	PG	2006-02-15 05:03:42	{"Deleted Scenes"}	'australia':18 'challeng':14 'dentist':11 'display':5 'emot':4 'goodfella':2 'man':8 'must':13 'rush':1 'squirrel':16
458	INDIAN LOVE	A Insightful Saga of a Mad Scientist And a Mad Scientist who must Kill a Astronaut in An Abandoned Fun House	2006	1	\N	4	0.99	135	26.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':21 'astronaut':18 'fun':22 'hous':23 'indian':1 'insight':4 'kill':16 'love':2 'mad':8,12 'must':15 'saga':5 'scientist':9,13
459	INFORMER DOUBLE	A Action-Packed Display of a Woman And a Dentist who must Redeem a Forensic Psychologist in The Canadian Rockies	2006	1	\N	4	4.99	74	23.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries}	'action':5 'action-pack':4 'canadian':22 'dentist':13 'display':7 'doubl':2 'forens':18 'inform':1 'must':15 'pack':6 'psychologist':19 'redeem':16 'rocki':23 'woman':10
460	INNOCENT USUAL	A Beautiful Drama of a Pioneer And a Crocodile who must Challenge a Student in The Outback	2006	1	\N	3	4.99	178	26.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'beauti':4 'challeng':14 'crocodil':11 'drama':5 'innoc':1 'must':13 'outback':19 'pioneer':8 'student':16 'usual':2
461	INSECTS STONE	A Epic Display of a Butler And a Dog who must Vanquish a Crocodile in A Manhattan Penthouse	2006	1	\N	3	0.99	123	14.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'butler':8 'crocodil':16 'display':5 'dog':11 'epic':4 'insect':1 'manhattan':19 'must':13 'penthous':20 'stone':2 'vanquish':14
462	INSIDER ARIZONA	A Astounding Saga of a Mad Scientist And a Hunter who must Pursue a Robot in A Baloon Factory	2006	1	\N	5	2.99	78	17.99	NC-17	2006-02-15 05:03:42	{Commentaries}	'arizona':2 'astound':4 'baloon':20 'factori':21 'hunter':12 'insid':1 'mad':8 'must':14 'pursu':15 'robot':17 'saga':5 'scientist':9
463	INSTINCT AIRPORT	A Touching Documentary of a Mad Cow And a Explorer who must Confront a Butler in A Manhattan Penthouse	2006	1	\N	4	2.99	116	21.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'airport':2 'butler':17 'confront':15 'cow':9 'documentari':5 'explor':12 'instinct':1 'mad':8 'manhattan':20 'must':14 'penthous':21 'touch':4
464	INTENTIONS EMPIRE	A Astounding Epistle of a Cat And a Cat who must Conquer a Mad Cow in A U-Boat	2006	1	\N	3	2.99	107	13.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'astound':4 'boat':22 'cat':8,11 'conquer':14 'cow':17 'empir':2 'epistl':5 'intent':1 'mad':16 'must':13 'u':21 'u-boat':20
465	INTERVIEW LIAISONS	A Action-Packed Reflection of a Student And a Butler who must Discover a Database Administrator in A Manhattan Penthouse	2006	1	\N	4	4.99	59	17.99	R	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'action':5 'action-pack':4 'administr':19 'butler':13 'databas':18 'discov':16 'interview':1 'liaison':2 'manhattan':22 'must':15 'pack':6 'penthous':23 'reflect':7 'student':10
466	INTOLERABLE INTENTIONS	A Awe-Inspiring Story of a Monkey And a Pastry Chef who must Succumb a Womanizer in A MySQL Convention	2006	1	\N	6	4.99	63	20.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'awe':5 'awe-inspir':4 'chef':14 'convent':23 'inspir':6 'intent':2 'intoler':1 'monkey':10 'must':16 'mysql':22 'pastri':13 'stori':7 'succumb':17 'woman':19
467	INTRIGUE WORST	A Fanciful Character Study of a Explorer And a Mad Scientist who must Vanquish a Squirrel in A Jet Boat	2006	1	\N	6	0.99	181	10.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'boat':22 'charact':5 'explor':9 'fanci':4 'intrigu':1 'jet':21 'mad':12 'must':15 'scientist':13 'squirrel':18 'studi':6 'vanquish':16 'worst':2
468	INVASION CYCLONE	A Lacklusture Character Study of a Mad Scientist And a Womanizer who must Outrace a Explorer in A Monastery	2006	1	\N	5	2.99	97	12.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'charact':5 'cyclon':2 'explor':18 'invas':1 'lacklustur':4 'mad':9 'monasteri':21 'must':15 'outrac':16 'scientist':10 'studi':6 'woman':13
469	IRON MOON	A Fast-Paced Documentary of a Mad Cow And a Boy who must Pursue a Dentist in A Baloon	2006	1	\N	7	4.99	46	27.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'baloon':22 'boy':14 'cow':11 'dentist':19 'documentari':7 'fast':5 'fast-pac':4 'iron':1 'mad':10 'moon':2 'must':16 'pace':6 'pursu':17
470	ISHTAR ROCKETEER	A Astounding Saga of a Dog And a Squirrel who must Conquer a Dog in An Abandoned Fun House	2006	1	\N	4	4.99	79	24.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'abandon':19 'astound':4 'conquer':14 'dog':8,16 'fun':20 'hous':21 'ishtar':1 'must':13 'rocket':2 'saga':5 'squirrel':11
471	ISLAND EXORCIST	A Fanciful Panorama of a Technical Writer And a Boy who must Find a Dentist in An Abandoned Fun House	2006	1	\N	7	2.99	84	23.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries}	'abandon':20 'boy':12 'dentist':17 'exorcist':2 'fanci':4 'find':15 'fun':21 'hous':22 'island':1 'must':14 'panorama':5 'technic':8 'writer':9
472	ITALIAN AFRICAN	A Astounding Character Study of a Monkey And a Moose who must Outgun a Cat in A U-Boat	2006	1	\N	3	4.99	174	24.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'african':2 'astound':4 'boat':22 'cat':17 'charact':5 'italian':1 'monkey':9 'moos':12 'must':14 'outgun':15 'studi':6 'u':21 'u-boat':20
473	JACKET FRISCO	A Insightful Reflection of a Womanizer And a Husband who must Conquer a Pastry Chef in A Baloon	2006	1	\N	5	2.99	181	16.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'baloon':20 'chef':17 'conquer':14 'frisco':2 'husband':11 'insight':4 'jacket':1 'must':13 'pastri':16 'reflect':5 'woman':8
474	JADE BUNCH	A Insightful Panorama of a Squirrel And a Mad Cow who must Confront a Student in The First Manned Space Station	2006	1	\N	6	2.99	174	21.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'bunch':2 'confront':15 'cow':12 'first':20 'insight':4 'jade':1 'mad':11 'man':21 'must':14 'panorama':5 'space':22 'squirrel':8 'station':23 'student':17
475	JAPANESE RUN	A Awe-Inspiring Epistle of a Feminist And a Girl who must Sink a Girl in The Outback	2006	1	\N	6	0.99	135	29.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'awe':5 'awe-inspir':4 'epistl':7 'feminist':10 'girl':13,18 'inspir':6 'japanes':1 'must':15 'outback':21 'run':2 'sink':16
476	JASON TRAP	A Thoughtful Tale of a Woman And a A Shark who must Conquer a Dog in A Monastery	2006	1	\N	5	2.99	130	9.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'conquer':15 'dog':17 'jason':1 'monasteri':20 'must':14 'shark':12 'tale':5 'thought':4 'trap':2 'woman':8
477	JAWBREAKER BROOKLYN	A Stunning Reflection of a Boat And a Pastry Chef who must Succumb a A Shark in A Jet Boat	2006	1	\N	5	0.99	118	15.99	PG	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'boat':8,22 'brooklyn':2 'chef':12 'jawbreak':1 'jet':21 'must':14 'pastri':11 'reflect':5 'shark':18 'stun':4 'succumb':15
478	JAWS HARRY	A Thrilling Display of a Database Administrator And a Monkey who must Overcome a Dog in An Abandoned Fun House	2006	1	\N	4	2.99	112	10.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'abandon':20 'administr':9 'databas':8 'display':5 'dog':17 'fun':21 'harri':2 'hous':22 'jaw':1 'monkey':12 'must':14 'overcom':15 'thrill':4
479	JEDI BENEATH	A Astounding Reflection of a Explorer And a Dentist who must Pursue a Student in Nigeria	2006	1	\N	7	0.99	128	12.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'astound':4 'beneath':2 'dentist':11 'explor':8 'jedi':1 'must':13 'nigeria':18 'pursu':14 'reflect':5 'student':16
480	JEEPERS WEDDING	A Astounding Display of a Composer And a Dog who must Kill a Pastry Chef in Soviet Georgia	2006	1	\N	3	2.99	84	29.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'astound':4 'chef':17 'compos':8 'display':5 'dog':11 'georgia':20 'jeeper':1 'kill':14 'must':13 'pastri':16 'soviet':19 'wed':2
481	JEKYLL FROGMEN	A Fanciful Epistle of a Student And a Astronaut who must Kill a Waitress in A Shark Tank	2006	1	\N	4	2.99	58	22.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'astronaut':11 'epistl':5 'fanci':4 'frogmen':2 'jekyl':1 'kill':14 'must':13 'shark':19 'student':8 'tank':20 'waitress':16
482	JEOPARDY ENCINO	A Boring Panorama of a Man And a Mad Cow who must Face a Explorer in Ancient India	2006	1	\N	3	0.99	102	12.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'ancient':19 'bore':4 'cow':12 'encino':2 'explor':17 'face':15 'india':20 'jeopardi':1 'mad':11 'man':8 'must':14 'panorama':5
483	JERICHO MULAN	A Amazing Yarn of a Hunter And a Butler who must Defeat a Boy in A Jet Boat	2006	1	\N	3	2.99	171	29.99	NC-17	2006-02-15 05:03:42	{Commentaries}	'amaz':4 'boat':20 'boy':16 'butler':11 'defeat':14 'hunter':8 'jericho':1 'jet':19 'mulan':2 'must':13 'yarn':5
484	JERK PAYCHECK	A Touching Character Study of a Pastry Chef And a Database Administrator who must Reach a A Shark in Ancient Japan	2006	1	\N	3	2.99	172	13.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'administr':14 'ancient':22 'charact':5 'chef':10 'databas':13 'japan':23 'jerk':1 'must':16 'pastri':9 'paycheck':2 'reach':17 'shark':20 'studi':6 'touch':4
485	JERSEY SASSY	A Lacklusture Documentary of a Madman And a Mad Cow who must Find a Feminist in Ancient Japan	2006	1	\N	6	4.99	60	16.99	PG	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'ancient':19 'cow':12 'documentari':5 'feminist':17 'find':15 'japan':20 'jersey':1 'lacklustur':4 'mad':11 'madman':8 'must':14 'sassi':2
486	JET NEIGHBORS	A Amazing Display of a Lumberjack And a Teacher who must Outrace a Woman in A U-Boat	2006	1	\N	7	4.99	59	14.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'amaz':4 'boat':21 'display':5 'jet':1 'lumberjack':8 'must':13 'neighbor':2 'outrac':14 'teacher':11 'u':20 'u-boat':19 'woman':16
487	JINGLE SAGEBRUSH	A Epic Character Study of a Feminist And a Student who must Meet a Woman in A Baloon	2006	1	\N	6	4.99	124	29.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'baloon':20 'charact':5 'epic':4 'feminist':9 'jingl':1 'meet':15 'must':14 'sagebrush':2 'student':12 'studi':6 'woman':17
488	JOON NORTHWEST	A Thrilling Panorama of a Technical Writer And a Car who must Discover a Forensic Psychologist in A Shark Tank	2006	1	\N	3	0.99	105	23.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'car':12 'discov':15 'forens':17 'joon':1 'must':14 'northwest':2 'panorama':5 'psychologist':18 'shark':21 'tank':22 'technic':8 'thrill':4 'writer':9
489	JUGGLER HARDLY	A Epic Story of a Mad Cow And a Astronaut who must Challenge a Car in California	2006	1	\N	4	0.99	54	14.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'astronaut':12 'california':19 'car':17 'challeng':15 'cow':9 'epic':4 'hard':2 'juggler':1 'mad':8 'must':14 'stori':5
490	JUMANJI BLADE	A Intrepid Yarn of a Husband And a Womanizer who must Pursue a Mad Scientist in New Orleans	2006	1	\N	4	2.99	121	13.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'blade':2 'husband':8 'intrepid':4 'jumanji':1 'mad':16 'must':13 'new':19 'orlean':20 'pursu':14 'scientist':17 'woman':11 'yarn':5
491	JUMPING WRATH	A Touching Epistle of a Monkey And a Feminist who must Discover a Boat in Berlin	2006	1	\N	4	0.99	74	18.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'berlin':18 'boat':16 'discov':14 'epistl':5 'feminist':11 'jump':1 'monkey':8 'must':13 'touch':4 'wrath':2
492	JUNGLE CLOSER	A Boring Character Study of a Boy And a Woman who must Battle a Astronaut in Australia	2006	1	\N	6	0.99	134	11.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'astronaut':17 'australia':19 'battl':15 'bore':4 'boy':9 'charact':5 'closer':2 'jungl':1 'must':14 'studi':6 'woman':12
493	KANE EXORCIST	A Epic Documentary of a Composer And a Robot who must Overcome a Car in Berlin	2006	1	\N	5	0.99	92	18.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'berlin':18 'car':16 'compos':8 'documentari':5 'epic':4 'exorcist':2 'kane':1 'must':13 'overcom':14 'robot':11
494	KARATE MOON	A Astounding Yarn of a Womanizer And a Dog who must Reach a Waitress in A MySQL Convention	2006	1	\N	4	0.99	120	21.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'astound':4 'convent':20 'dog':11 'karat':1 'moon':2 'must':13 'mysql':19 'reach':14 'waitress':16 'woman':8 'yarn':5
495	KENTUCKIAN GIANT	A Stunning Yarn of a Woman And a Frisbee who must Escape a Waitress in A U-Boat	2006	1	\N	5	2.99	169	10.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'boat':21 'escap':14 'frisbe':11 'giant':2 'kentuckian':1 'must':13 'stun':4 'u':20 'u-boat':19 'waitress':16 'woman':8 'yarn':5
496	KICK SAVANNAH	A Emotional Drama of a Monkey And a Robot who must Defeat a Monkey in New Orleans	2006	1	\N	3	0.99	179	10.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'defeat':14 'drama':5 'emot':4 'kick':1 'monkey':8,16 'must':13 'new':18 'orlean':19 'robot':11 'savannah':2
497	KILL BROTHERHOOD	A Touching Display of a Hunter And a Secret Agent who must Redeem a Husband in The Outback	2006	1	\N	4	0.99	54	15.99	G	2006-02-15 05:03:42	{Trailers,Commentaries}	'agent':12 'brotherhood':2 'display':5 'hunter':8 'husband':17 'kill':1 'must':14 'outback':20 'redeem':15 'secret':11 'touch':4
498	KILLER INNOCENT	A Fanciful Character Study of a Student And a Explorer who must Succumb a Composer in An Abandoned Mine Shaft	2006	1	\N	7	2.99	161	11.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'abandon':20 'charact':5 'compos':17 'explor':12 'fanci':4 'innoc':2 'killer':1 'mine':21 'must':14 'shaft':22 'student':9 'studi':6 'succumb':15
499	KING EVOLUTION	A Action-Packed Tale of a Boy And a Lumberjack who must Chase a Madman in A Baloon	2006	1	\N	3	4.99	184	24.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'action':5 'action-pack':4 'baloon':21 'boy':10 'chase':16 'evolut':2 'king':1 'lumberjack':13 'madman':18 'must':15 'pack':6 'tale':7
500	KISS GLORY	A Lacklusture Reflection of a Girl And a Husband who must Find a Robot in The Canadian Rockies	2006	1	\N	5	4.99	163	11.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'canadian':19 'find':14 'girl':8 'glori':2 'husband':11 'kiss':1 'lacklustur':4 'must':13 'reflect':5 'robot':16 'rocki':20
501	KISSING DOLLS	A Insightful Reflection of a Pioneer And a Teacher who must Build a Composer in The First Manned Space Station	2006	1	\N	3	4.99	141	9.99	R	2006-02-15 05:03:42	{Trailers}	'build':14 'compos':16 'doll':2 'first':19 'insight':4 'kiss':1 'man':20 'must':13 'pioneer':8 'reflect':5 'space':21 'station':22 'teacher':11
502	KNOCK WARLOCK	A Unbelieveable Story of a Teacher And a Boat who must Confront a Moose in A Baloon	2006	1	\N	4	2.99	71	21.99	PG-13	2006-02-15 05:03:42	{Trailers}	'baloon':19 'boat':11 'confront':14 'knock':1 'moos':16 'must':13 'stori':5 'teacher':8 'unbeliev':4 'warlock':2
503	KRAMER CHOCOLATE	A Amazing Yarn of a Robot And a Pastry Chef who must Redeem a Mad Scientist in The Outback	2006	1	\N	3	2.99	171	24.99	R	2006-02-15 05:03:42	{Trailers}	'amaz':4 'chef':12 'chocol':2 'kramer':1 'mad':17 'must':14 'outback':21 'pastri':11 'redeem':15 'robot':8 'scientist':18 'yarn':5
504	KWAI HOMEWARD	A Amazing Drama of a Car And a Squirrel who must Pursue a Car in Soviet Georgia	2006	1	\N	5	0.99	46	25.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'amaz':4 'car':8,16 'drama':5 'georgia':19 'homeward':2 'kwai':1 'must':13 'pursu':14 'soviet':18 'squirrel':11
505	LABYRINTH LEAGUE	A Awe-Inspiring Saga of a Composer And a Frisbee who must Succumb a Pioneer in The Sahara Desert	2006	1	\N	6	2.99	46	24.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'awe':5 'awe-inspir':4 'compos':10 'desert':22 'frisbe':13 'inspir':6 'labyrinth':1 'leagu':2 'must':15 'pioneer':18 'saga':7 'sahara':21 'succumb':16
506	LADY STAGE	A Beautiful Character Study of a Woman And a Man who must Pursue a Explorer in A U-Boat	2006	1	\N	4	4.99	67	14.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'beauti':4 'boat':22 'charact':5 'explor':17 'ladi':1 'man':12 'must':14 'pursu':15 'stage':2 'studi':6 'u':21 'u-boat':20 'woman':9
507	LADYBUGS ARMAGEDDON	A Fateful Reflection of a Dog And a Mad Scientist who must Meet a Mad Scientist in New Orleans	2006	1	\N	4	0.99	113	13.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes"}	'armageddon':2 'dog':8 'fate':4 'ladybug':1 'mad':11,17 'meet':15 'must':14 'new':20 'orlean':21 'reflect':5 'scientist':12,18
508	LAMBS CINCINATTI	A Insightful Story of a Man And a Feminist who must Fight a Composer in Australia	2006	1	\N	6	4.99	144	18.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'australia':18 'cincinatti':2 'compos':16 'feminist':11 'fight':14 'insight':4 'lamb':1 'man':8 'must':13 'stori':5
509	LANGUAGE COWBOY	A Epic Yarn of a Cat And a Madman who must Vanquish a Dentist in An Abandoned Amusement Park	2006	1	\N	5	0.99	78	26.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'abandon':19 'amus':20 'cat':8 'cowboy':2 'dentist':16 'epic':4 'languag':1 'madman':11 'must':13 'park':21 'vanquish':14 'yarn':5
510	LAWLESS VISION	A Insightful Yarn of a Boy And a Sumo Wrestler who must Outgun a Car in The Outback	2006	1	\N	6	4.99	181	29.99	G	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'boy':8 'car':17 'insight':4 'lawless':1 'must':14 'outback':20 'outgun':15 'sumo':11 'vision':2 'wrestler':12 'yarn':5
511	LAWRENCE LOVE	A Fanciful Yarn of a Database Administrator And a Mad Cow who must Pursue a Womanizer in Berlin	2006	1	\N	7	0.99	175	23.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'administr':9 'berlin':20 'cow':13 'databas':8 'fanci':4 'lawrenc':1 'love':2 'mad':12 'must':15 'pursu':16 'woman':18 'yarn':5
512	LEAGUE HELLFIGHTERS	A Thoughtful Saga of a A Shark And a Monkey who must Outgun a Student in Ancient China	2006	1	\N	5	4.99	110	25.99	PG-13	2006-02-15 05:03:42	{Trailers}	'ancient':19 'china':20 'hellfight':2 'leagu':1 'monkey':12 'must':14 'outgun':15 'saga':5 'shark':9 'student':17 'thought':4
513	LEATHERNECKS DWARFS	A Fateful Reflection of a Dog And a Mad Cow who must Outrace a Teacher in An Abandoned Mine Shaft	2006	1	\N	6	2.99	153	21.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'abandon':20 'cow':12 'dog':8 'dwarf':2 'fate':4 'leatherneck':1 'mad':11 'mine':21 'must':14 'outrac':15 'reflect':5 'shaft':22 'teacher':17
514	LEBOWSKI SOLDIERS	A Beautiful Epistle of a Secret Agent And a Pioneer who must Chase a Astronaut in Ancient China	2006	1	\N	6	2.99	69	17.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'agent':9 'ancient':19 'astronaut':17 'beauti':4 'chase':15 'china':20 'epistl':5 'lebowski':1 'must':14 'pioneer':12 'secret':8 'soldier':2
515	LEGALLY SECRETARY	A Astounding Tale of a A Shark And a Moose who must Meet a Womanizer in The Sahara Desert	2006	1	\N	7	4.99	113	14.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'astound':4 'desert':21 'legal':1 'meet':15 'moos':12 'must':14 'sahara':20 'secretari':2 'shark':9 'tale':5 'woman':17
516	LEGEND JEDI	A Awe-Inspiring Epistle of a Pioneer And a Student who must Outgun a Crocodile in The Outback	2006	1	\N	7	0.99	59	18.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'awe':5 'awe-inspir':4 'crocodil':18 'epistl':7 'inspir':6 'jedi':2 'legend':1 'must':15 'outback':21 'outgun':16 'pioneer':10 'student':13
517	LESSON CLEOPATRA	A Emotional Display of a Man And a Explorer who must Build a Boy in A Manhattan Penthouse	2006	1	\N	3	0.99	167	28.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'boy':16 'build':14 'cleopatra':2 'display':5 'emot':4 'explor':11 'lesson':1 'man':8 'manhattan':19 'must':13 'penthous':20
518	LIAISONS SWEET	A Boring Drama of a A Shark And a Explorer who must Redeem a Waitress in The Canadian Rockies	2006	1	\N	5	4.99	140	15.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'bore':4 'canadian':20 'drama':5 'explor':12 'liaison':1 'must':14 'redeem':15 'rocki':21 'shark':9 'sweet':2 'waitress':17
519	LIBERTY MAGNIFICENT	A Boring Drama of a Student And a Cat who must Sink a Technical Writer in A Baloon	2006	1	\N	3	2.99	138	27.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'baloon':20 'bore':4 'cat':11 'drama':5 'liberti':1 'magnific':2 'must':13 'sink':14 'student':8 'technic':16 'writer':17
520	LICENSE WEEKEND	A Insightful Story of a Man And a Husband who must Overcome a Madman in A Monastery	2006	1	\N	7	2.99	91	28.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'husband':11 'insight':4 'licens':1 'madman':16 'man':8 'monasteri':19 'must':13 'overcom':14 'stori':5 'weekend':2
521	LIES TREATMENT	A Fast-Paced Character Study of a Dentist And a Moose who must Defeat a Composer in The First Manned Space Station	2006	1	\N	7	4.99	147	28.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'charact':7 'compos':19 'defeat':17 'dentist':11 'fast':5 'fast-pac':4 'first':22 'lie':1 'man':23 'moos':14 'must':16 'pace':6 'space':24 'station':25 'studi':8 'treatment':2
522	LIFE TWISTED	A Thrilling Reflection of a Teacher And a Composer who must Find a Man in The First Manned Space Station	2006	1	\N	4	2.99	137	9.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'compos':11 'find':14 'first':19 'life':1 'man':16,20 'must':13 'reflect':5 'space':21 'station':22 'teacher':8 'thrill':4 'twist':2
523	LIGHTS DEER	A Unbelieveable Epistle of a Dog And a Woman who must Confront a Moose in The Gulf of Mexico	2006	1	\N	7	0.99	174	21.99	R	2006-02-15 05:03:42	{Commentaries}	'confront':14 'deer':2 'dog':8 'epistl':5 'gulf':19 'light':1 'mexico':21 'moos':16 'must':13 'unbeliev':4 'woman':11
524	LION UNCUT	A Intrepid Display of a Pastry Chef And a Cat who must Kill a A Shark in Ancient China	2006	1	\N	6	0.99	50	13.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'ancient':20 'cat':12 'chef':9 'china':21 'display':5 'intrepid':4 'kill':15 'lion':1 'must':14 'pastri':8 'shark':18 'uncut':2
525	LOATHING LEGALLY	A Boring Epistle of a Pioneer And a Mad Scientist who must Escape a Frisbee in The Gulf of Mexico	2006	1	\N	4	0.99	140	29.99	R	2006-02-15 05:03:42	{"Deleted Scenes"}	'bore':4 'epistl':5 'escap':15 'frisbe':17 'gulf':20 'legal':2 'loath':1 'mad':11 'mexico':22 'must':14 'pioneer':8 'scientist':12
526	LOCK REAR	A Thoughtful Character Study of a Squirrel And a Technical Writer who must Outrace a Student in Ancient Japan	2006	1	\N	7	2.99	120	10.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'ancient':20 'charact':5 'japan':21 'lock':1 'must':15 'outrac':16 'rear':2 'squirrel':9 'student':18 'studi':6 'technic':12 'thought':4 'writer':13
527	LOLA AGENT	A Astounding Tale of a Mad Scientist And a Husband who must Redeem a Database Administrator in Ancient Japan	2006	1	\N	4	4.99	85	24.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'administr':18 'agent':2 'ancient':20 'astound':4 'databas':17 'husband':12 'japan':21 'lola':1 'mad':8 'must':14 'redeem':15 'scientist':9 'tale':5
528	LOLITA WORLD	A Thrilling Drama of a Girl And a Robot who must Redeem a Waitress in An Abandoned Mine Shaft	2006	1	\N	4	2.99	155	25.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'abandon':19 'drama':5 'girl':8 'lolita':1 'mine':20 'must':13 'redeem':14 'robot':11 'shaft':21 'thrill':4 'waitress':16 'world':2
529	LONELY ELEPHANT	A Intrepid Story of a Student And a Dog who must Challenge a Explorer in Soviet Georgia	2006	1	\N	3	2.99	67	12.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'challeng':14 'dog':11 'eleph':2 'explor':16 'georgia':19 'intrepid':4 'lone':1 'must':13 'soviet':18 'stori':5 'student':8
530	LORD ARIZONA	A Action-Packed Display of a Frisbee And a Pastry Chef who must Pursue a Crocodile in A Jet Boat	2006	1	\N	5	2.99	108	27.99	PG-13	2006-02-15 05:03:42	{Trailers}	'action':5 'action-pack':4 'arizona':2 'boat':23 'chef':14 'crocodil':19 'display':7 'frisbe':10 'jet':22 'lord':1 'must':16 'pack':6 'pastri':13 'pursu':17
531	LOSE INCH	A Stunning Reflection of a Student And a Technical Writer who must Battle a Butler in The First Manned Space Station	2006	1	\N	3	0.99	137	18.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'battl':15 'butler':17 'first':20 'inch':2 'lose':1 'man':21 'must':14 'reflect':5 'space':22 'station':23 'student':8 'stun':4 'technic':11 'writer':12
532	LOSER HUSTLER	A Stunning Drama of a Robot And a Feminist who must Outgun a Butler in Nigeria	2006	1	\N	5	4.99	80	28.99	PG	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'butler':16 'drama':5 'feminist':11 'hustler':2 'loser':1 'must':13 'nigeria':18 'outgun':14 'robot':8 'stun':4
533	LOST BIRD	A Emotional Character Study of a Robot And a A Shark who must Defeat a Technical Writer in A Manhattan Penthouse	2006	1	\N	4	2.99	98	21.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'bird':2 'charact':5 'defeat':16 'emot':4 'lost':1 'manhattan':22 'must':15 'penthous':23 'robot':9 'shark':13 'studi':6 'technic':18 'writer':19
534	LOUISIANA HARRY	A Lacklusture Drama of a Girl And a Technical Writer who must Redeem a Monkey in A Shark Tank	2006	1	\N	5	0.99	70	18.99	PG-13	2006-02-15 05:03:42	{Trailers}	'drama':5 'girl':8 'harri':2 'lacklustur':4 'louisiana':1 'monkey':17 'must':14 'redeem':15 'shark':20 'tank':21 'technic':11 'writer':12
535	LOVE SUICIDES	A Brilliant Panorama of a Hunter And a Explorer who must Pursue a Dentist in An Abandoned Fun House	2006	1	\N	6	0.99	181	21.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'abandon':19 'brilliant':4 'dentist':16 'explor':11 'fun':20 'hous':21 'hunter':8 'love':1 'must':13 'panorama':5 'pursu':14 'suicid':2
536	LOVELY JINGLE	A Fanciful Yarn of a Crocodile And a Forensic Psychologist who must Discover a Crocodile in The Outback	2006	1	\N	3	2.99	65	18.99	PG	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'crocodil':8,17 'discov':15 'fanci':4 'forens':11 'jingl':2 'love':1 'must':14 'outback':20 'psychologist':12 'yarn':5
537	LOVER TRUMAN	A Emotional Yarn of a Robot And a Boy who must Outgun a Technical Writer in A U-Boat	2006	1	\N	3	2.99	75	29.99	G	2006-02-15 05:03:42	{Trailers}	'boat':22 'boy':11 'emot':4 'lover':1 'must':13 'outgun':14 'robot':8 'technic':16 'truman':2 'u':21 'u-boat':20 'writer':17 'yarn':5
538	LOVERBOY ATTACKS	A Boring Story of a Car And a Butler who must Build a Girl in Soviet Georgia	2006	1	\N	7	0.99	162	19.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'attack':2 'bore':4 'build':14 'butler':11 'car':8 'georgia':19 'girl':16 'loverboy':1 'must':13 'soviet':18 'stori':5
539	LUCK OPUS	A Boring Display of a Moose And a Squirrel who must Outrace a Teacher in A Shark Tank	2006	1	\N	7	2.99	152	21.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'bore':4 'display':5 'luck':1 'moos':8 'must':13 'opus':2 'outrac':14 'shark':19 'squirrel':11 'tank':20 'teacher':16
540	LUCKY FLYING	A Lacklusture Character Study of a A Shark And a Man who must Find a Forensic Psychologist in A U-Boat	2006	1	\N	7	2.99	97	10.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'boat':24 'charact':5 'find':16 'fli':2 'forens':18 'lacklustur':4 'lucki':1 'man':13 'must':15 'psychologist':19 'shark':10 'studi':6 'u':23 'u-boat':22
541	LUKE MUMMY	A Taut Character Study of a Boy And a Robot who must Redeem a Mad Scientist in Ancient India	2006	1	\N	5	2.99	74	21.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'ancient':20 'boy':9 'charact':5 'india':21 'luke':1 'mad':17 'mummi':2 'must':14 'redeem':15 'robot':12 'scientist':18 'studi':6 'taut':4
542	LUST LOCK	A Fanciful Panorama of a Hunter And a Dentist who must Meet a Secret Agent in The Sahara Desert	2006	1	\N	3	2.99	52	28.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'agent':17 'dentist':11 'desert':21 'fanci':4 'hunter':8 'lock':2 'lust':1 'meet':14 'must':13 'panorama':5 'sahara':20 'secret':16
543	MADIGAN DORADO	A Astounding Character Study of a A Shark And a A Shark who must Discover a Crocodile in The Outback	2006	1	\N	5	4.99	116	20.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'astound':4 'charact':5 'crocodil':19 'discov':17 'dorado':2 'madigan':1 'must':16 'outback':22 'shark':10,14 'studi':6
544	MADISON TRAP	A Awe-Inspiring Reflection of a Monkey And a Dentist who must Overcome a Pioneer in A U-Boat	2006	1	\N	4	2.99	147	11.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'awe':5 'awe-inspir':4 'boat':23 'dentist':13 'inspir':6 'madison':1 'monkey':10 'must':15 'overcom':16 'pioneer':18 'reflect':7 'trap':2 'u':22 'u-boat':21
545	MADNESS ATTACKS	A Fanciful Tale of a Squirrel And a Boat who must Defeat a Crocodile in The Gulf of Mexico	2006	1	\N	4	0.99	178	14.99	PG-13	2006-02-15 05:03:42	{Trailers}	'attack':2 'boat':11 'crocodil':16 'defeat':14 'fanci':4 'gulf':19 'mad':1 'mexico':21 'must':13 'squirrel':8 'tale':5
546	MADRE GABLES	A Intrepid Panorama of a Sumo Wrestler And a Forensic Psychologist who must Discover a Moose in The First Manned Space Station	2006	1	\N	7	2.99	98	27.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'discov':16 'first':21 'forens':12 'gabl':2 'intrepid':4 'madr':1 'man':22 'moos':18 'must':15 'panorama':5 'psychologist':13 'space':23 'station':24 'sumo':8 'wrestler':9
547	MAGIC MALLRATS	A Touching Documentary of a Pastry Chef And a Pastry Chef who must Build a Mad Scientist in California	2006	1	\N	3	0.99	117	19.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'build':16 'california':21 'chef':9,13 'documentari':5 'mad':18 'magic':1 'mallrat':2 'must':15 'pastri':8,12 'scientist':19 'touch':4
548	MAGNIFICENT CHITTY	A Insightful Story of a Teacher And a Hunter who must Face a Mad Cow in California	2006	1	\N	3	2.99	53	27.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'california':19 'chitti':2 'cow':17 'face':14 'hunter':11 'insight':4 'mad':16 'magnific':1 'must':13 'stori':5 'teacher':8
549	MAGNOLIA FORRESTER	A Thoughtful Documentary of a Composer And a Explorer who must Conquer a Dentist in New Orleans	2006	1	\N	4	0.99	171	28.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'compos':8 'conquer':14 'dentist':16 'documentari':5 'explor':11 'forrest':2 'magnolia':1 'must':13 'new':18 'orlean':19 'thought':4
550	MAGUIRE APACHE	A Fast-Paced Reflection of a Waitress And a Hunter who must Defeat a Forensic Psychologist in A Baloon	2006	1	\N	6	2.99	74	22.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries}	'apach':2 'baloon':22 'defeat':16 'fast':5 'fast-pac':4 'forens':18 'hunter':13 'maguir':1 'must':15 'pace':6 'psychologist':19 'reflect':7 'waitress':10
551	MAIDEN HOME	A Lacklusture Saga of a Moose And a Teacher who must Kill a Forensic Psychologist in A MySQL Convention	2006	1	\N	3	4.99	138	9.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'convent':21 'forens':16 'home':2 'kill':14 'lacklustur':4 'maiden':1 'moos':8 'must':13 'mysql':20 'psychologist':17 'saga':5 'teacher':11
552	MAJESTIC FLOATS	A Thrilling Character Study of a Moose And a Student who must Escape a Butler in The First Manned Space Station	2006	1	\N	5	0.99	130	15.99	PG	2006-02-15 05:03:42	{Trailers}	'butler':17 'charact':5 'escap':15 'first':20 'float':2 'majest':1 'man':21 'moos':9 'must':14 'space':22 'station':23 'student':12 'studi':6 'thrill':4
553	MAKER GABLES	A Stunning Display of a Moose And a Database Administrator who must Pursue a Composer in A Jet Boat	2006	1	\N	4	0.99	136	12.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'administr':12 'boat':21 'compos':17 'databas':11 'display':5 'gabl':2 'jet':20 'maker':1 'moos':8 'must':14 'pursu':15 'stun':4
554	MALKOVICH PET	A Intrepid Reflection of a Waitress And a A Shark who must Kill a Squirrel in The Outback	2006	1	\N	6	2.99	159	22.99	G	2006-02-15 05:03:42	{"Behind the Scenes"}	'intrepid':4 'kill':15 'malkovich':1 'must':14 'outback':20 'pet':2 'reflect':5 'shark':12 'squirrel':17 'waitress':8
555	MALLRATS UNITED	A Thrilling Yarn of a Waitress And a Dentist who must Find a Hunter in A Monastery	2006	1	\N	4	0.99	133	25.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'dentist':11 'find':14 'hunter':16 'mallrat':1 'monasteri':19 'must':13 'thrill':4 'unit':2 'waitress':8 'yarn':5
556	MALTESE HOPE	A Fast-Paced Documentary of a Crocodile And a Sumo Wrestler who must Conquer a Explorer in California	2006	1	\N	6	4.99	127	26.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'california':21 'conquer':17 'crocodil':10 'documentari':7 'explor':19 'fast':5 'fast-pac':4 'hope':2 'maltes':1 'must':16 'pace':6 'sumo':13 'wrestler':14
557	MANCHURIAN CURTAIN	A Stunning Tale of a Mad Cow And a Boy who must Battle a Boy in Berlin	2006	1	\N	5	2.99	177	27.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'battl':15 'berlin':19 'boy':12,17 'cow':9 'curtain':2 'mad':8 'manchurian':1 'must':14 'stun':4 'tale':5
558	MANNEQUIN WORST	A Astounding Saga of a Mad Cow And a Pastry Chef who must Discover a Husband in Ancient India	2006	1	\N	3	2.99	71	18.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'ancient':20 'astound':4 'chef':13 'cow':9 'discov':16 'husband':18 'india':21 'mad':8 'mannequin':1 'must':15 'pastri':12 'saga':5 'worst':2
559	MARRIED GO	A Fanciful Story of a Womanizer And a Dog who must Face a Forensic Psychologist in The Sahara Desert	2006	1	\N	7	2.99	114	22.99	G	2006-02-15 05:03:42	{"Behind the Scenes"}	'desert':21 'dog':11 'face':14 'fanci':4 'forens':16 'go':2 'marri':1 'must':13 'psychologist':17 'sahara':20 'stori':5 'woman':8
560	MARS ROMAN	A Boring Drama of a Car And a Dog who must Succumb a Madman in Soviet Georgia	2006	1	\N	6	0.99	62	21.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'bore':4 'car':8 'dog':11 'drama':5 'georgia':19 'madman':16 'mar':1 'must':13 'roman':2 'soviet':18 'succumb':14
561	MASK PEACH	A Boring Character Study of a Student And a Robot who must Meet a Woman in California	2006	1	\N	6	2.99	123	26.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'bore':4 'california':19 'charact':5 'mask':1 'meet':15 'must':14 'peach':2 'robot':12 'student':9 'studi':6 'woman':17
562	MASKED BUBBLE	A Fanciful Documentary of a Pioneer And a Boat who must Pursue a Pioneer in An Abandoned Mine Shaft	2006	1	\N	6	0.99	151	12.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'abandon':19 'boat':11 'bubbl':2 'documentari':5 'fanci':4 'mask':1 'mine':20 'must':13 'pioneer':8,16 'pursu':14 'shaft':21
563	MASSACRE USUAL	A Fateful Reflection of a Waitress And a Crocodile who must Challenge a Forensic Psychologist in California	2006	1	\N	6	4.99	165	16.99	R	2006-02-15 05:03:42	{Commentaries}	'california':19 'challeng':14 'crocodil':11 'fate':4 'forens':16 'massacr':1 'must':13 'psychologist':17 'reflect':5 'usual':2 'waitress':8
564	MASSAGE IMAGE	A Fateful Drama of a Frisbee And a Crocodile who must Vanquish a Dog in The First Manned Space Station	2006	1	\N	4	2.99	161	11.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'crocodil':11 'dog':16 'drama':5 'fate':4 'first':19 'frisbe':8 'imag':2 'man':20 'massag':1 'must':13 'space':21 'station':22 'vanquish':14
565	MATRIX SNOWMAN	A Action-Packed Saga of a Womanizer And a Woman who must Overcome a Student in California	2006	1	\N	6	4.99	56	9.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'action':5 'action-pack':4 'california':20 'matrix':1 'must':15 'overcom':16 'pack':6 'saga':7 'snowman':2 'student':18 'woman':10,13
566	MAUDE MOD	A Beautiful Documentary of a Forensic Psychologist And a Cat who must Reach a Astronaut in Nigeria	2006	1	\N	6	0.99	72	20.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'astronaut':17 'beauti':4 'cat':12 'documentari':5 'forens':8 'maud':1 'mod':2 'must':14 'nigeria':19 'psychologist':9 'reach':15
567	MEET CHOCOLATE	A Boring Documentary of a Dentist And a Butler who must Confront a Monkey in A MySQL Convention	2006	1	\N	3	2.99	80	26.99	G	2006-02-15 05:03:42	{Trailers}	'bore':4 'butler':11 'chocol':2 'confront':14 'convent':20 'dentist':8 'documentari':5 'meet':1 'monkey':16 'must':13 'mysql':19
568	MEMENTO ZOOLANDER	A Touching Epistle of a Squirrel And a Explorer who must Redeem a Pastry Chef in The Sahara Desert	2006	1	\N	4	4.99	77	11.99	NC-17	2006-02-15 05:03:42	{"Behind the Scenes"}	'chef':17 'desert':21 'epistl':5 'explor':11 'memento':1 'must':13 'pastri':16 'redeem':14 'sahara':20 'squirrel':8 'touch':4 'zooland':2
569	MENAGERIE RUSHMORE	A Unbelieveable Panorama of a Composer And a Butler who must Overcome a Database Administrator in The First Manned Space Station	2006	1	\N	7	2.99	147	18.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'administr':17 'butler':11 'compos':8 'databas':16 'first':20 'man':21 'menageri':1 'must':13 'overcom':14 'panorama':5 'rushmor':2 'space':22 'station':23 'unbeliev':4
570	MERMAID INSECTS	A Lacklusture Drama of a Waitress And a Husband who must Fight a Husband in California	2006	1	\N	5	4.99	104	20.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'california':18 'drama':5 'fight':14 'husband':11,16 'insect':2 'lacklustur':4 'mermaid':1 'must':13 'waitress':8
571	METAL ARMAGEDDON	A Thrilling Display of a Lumberjack And a Crocodile who must Meet a Monkey in A Baloon Factory	2006	1	\N	6	2.99	161	26.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'armageddon':2 'baloon':19 'crocodil':11 'display':5 'factori':20 'lumberjack':8 'meet':14 'metal':1 'monkey':16 'must':13 'thrill':4
572	METROPOLIS COMA	A Emotional Saga of a Database Administrator And a Pastry Chef who must Confront a Teacher in A Baloon Factory	2006	1	\N	4	2.99	64	9.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'administr':9 'baloon':21 'chef':13 'coma':2 'confront':16 'databas':8 'emot':4 'factori':22 'metropoli':1 'must':15 'pastri':12 'saga':5 'teacher':18
573	MICROCOSMOS PARADISE	A Touching Character Study of a Boat And a Student who must Sink a A Shark in Nigeria	2006	1	\N	6	2.99	105	22.99	PG-13	2006-02-15 05:03:42	{Commentaries}	'boat':9 'charact':5 'microcosmo':1 'must':14 'nigeria':20 'paradis':2 'shark':18 'sink':15 'student':12 'studi':6 'touch':4
574	MIDNIGHT WESTWARD	A Taut Reflection of a Husband And a A Shark who must Redeem a Pastry Chef in A Monastery	2006	1	\N	3	0.99	86	19.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'chef':18 'husband':8 'midnight':1 'monasteri':21 'must':14 'pastri':17 'redeem':15 'reflect':5 'shark':12 'taut':4 'westward':2
575	MIDSUMMER GROUNDHOG	A Fateful Panorama of a Moose And a Dog who must Chase a Crocodile in Ancient Japan	2006	1	\N	3	4.99	48	27.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'ancient':18 'chase':14 'crocodil':16 'dog':11 'fate':4 'groundhog':2 'japan':19 'midsumm':1 'moos':8 'must':13 'panorama':5
576	MIGHTY LUCK	A Astounding Epistle of a Mad Scientist And a Pioneer who must Escape a Database Administrator in A MySQL Convention	2006	1	\N	7	2.99	122	13.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'administr':18 'astound':4 'convent':22 'databas':17 'epistl':5 'escap':15 'luck':2 'mad':8 'mighti':1 'must':14 'mysql':21 'pioneer':12 'scientist':9
577	MILE MULAN	A Lacklusture Epistle of a Cat And a Husband who must Confront a Boy in A MySQL Convention	2006	1	\N	4	0.99	64	10.99	PG	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'boy':16 'cat':8 'confront':14 'convent':20 'epistl':5 'husband':11 'lacklustur':4 'mile':1 'mulan':2 'must':13 'mysql':19
578	MILLION ACE	A Brilliant Documentary of a Womanizer And a Squirrel who must Find a Technical Writer in The Sahara Desert	2006	1	\N	4	4.99	142	16.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'ace':2 'brilliant':4 'desert':21 'documentari':5 'find':14 'million':1 'must':13 'sahara':20 'squirrel':11 'technic':16 'woman':8 'writer':17
579	MINDS TRUMAN	A Taut Yarn of a Mad Scientist And a Crocodile who must Outgun a Database Administrator in A Monastery	2006	1	\N	3	4.99	149	22.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'administr':18 'crocodil':12 'databas':17 'mad':8 'mind':1 'monasteri':21 'must':14 'outgun':15 'scientist':9 'taut':4 'truman':2 'yarn':5
580	MINE TITANS	A Amazing Yarn of a Robot And a Womanizer who must Discover a Forensic Psychologist in Berlin	2006	1	\N	3	4.99	166	12.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'amaz':4 'berlin':19 'discov':14 'forens':16 'mine':1 'must':13 'psychologist':17 'robot':8 'titan':2 'woman':11 'yarn':5
581	MINORITY KISS	A Insightful Display of a Lumberjack And a Sumo Wrestler who must Meet a Man in The Outback	2006	1	\N	4	0.99	59	16.99	G	2006-02-15 05:03:42	{Trailers}	'display':5 'insight':4 'kiss':2 'lumberjack':8 'man':17 'meet':15 'minor':1 'must':14 'outback':20 'sumo':11 'wrestler':12
582	MIRACLE VIRTUAL	A Touching Epistle of a Butler And a Boy who must Find a Mad Scientist in The Sahara Desert	2006	1	\N	3	2.99	162	19.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'boy':11 'butler':8 'desert':21 'epistl':5 'find':14 'mad':16 'miracl':1 'must':13 'sahara':20 'scientist':17 'touch':4 'virtual':2
583	MISSION ZOOLANDER	A Intrepid Story of a Sumo Wrestler And a Teacher who must Meet a A Shark in An Abandoned Fun House	2006	1	\N	3	4.99	164	26.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'abandon':21 'fun':22 'hous':23 'intrepid':4 'meet':15 'mission':1 'must':14 'shark':18 'stori':5 'sumo':8 'teacher':12 'wrestler':9 'zooland':2
584	MIXED DOORS	A Taut Drama of a Womanizer And a Lumberjack who must Succumb a Pioneer in Ancient India	2006	1	\N	6	2.99	180	26.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'ancient':18 'door':2 'drama':5 'india':19 'lumberjack':11 'mix':1 'must':13 'pioneer':16 'succumb':14 'taut':4 'woman':8
585	MOB DUFFEL	A Unbelieveable Documentary of a Frisbee And a Boat who must Meet a Boy in The Canadian Rockies	2006	1	\N	4	0.99	105	25.99	G	2006-02-15 05:03:42	{Trailers}	'boat':11 'boy':16 'canadian':19 'documentari':5 'duffel':2 'frisbe':8 'meet':14 'mob':1 'must':13 'rocki':20 'unbeliev':4
586	MOCKINGBIRD HOLLYWOOD	A Thoughtful Panorama of a Man And a Car who must Sink a Composer in Berlin	2006	1	\N	4	0.99	60	27.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'berlin':18 'car':11 'compos':16 'hollywood':2 'man':8 'mockingbird':1 'must':13 'panorama':5 'sink':14 'thought':4
587	MOD SECRETARY	A Boring Documentary of a Mad Cow And a Cat who must Build a Lumberjack in New Orleans	2006	1	\N	6	4.99	77	20.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'bore':4 'build':15 'cat':12 'cow':9 'documentari':5 'lumberjack':17 'mad':8 'mod':1 'must':14 'new':19 'orlean':20 'secretari':2
588	MODEL FISH	A Beautiful Panorama of a Boat And a Crocodile who must Outrace a Dog in Australia	2006	1	\N	4	4.99	175	11.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'australia':18 'beauti':4 'boat':8 'crocodil':11 'dog':16 'fish':2 'model':1 'must':13 'outrac':14 'panorama':5
589	MODERN DORADO	A Awe-Inspiring Story of a Butler And a Sumo Wrestler who must Redeem a Boy in New Orleans	2006	1	\N	3	0.99	74	20.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'awe':5 'awe-inspir':4 'boy':19 'butler':10 'dorado':2 'inspir':6 'modern':1 'must':16 'new':21 'orlean':22 'redeem':17 'stori':7 'sumo':13 'wrestler':14
590	MONEY HAROLD	A Touching Tale of a Explorer And a Boat who must Defeat a Robot in Australia	2006	1	\N	3	2.99	135	17.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'australia':18 'boat':11 'defeat':14 'explor':8 'harold':2 'money':1 'must':13 'robot':16 'tale':5 'touch':4
591	MONSOON CAUSE	A Astounding Tale of a Crocodile And a Car who must Outrace a Squirrel in A U-Boat	2006	1	\N	6	4.99	182	20.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'astound':4 'boat':21 'car':11 'caus':2 'crocodil':8 'monsoon':1 'must':13 'outrac':14 'squirrel':16 'tale':5 'u':20 'u-boat':19
592	MONSTER SPARTACUS	A Fast-Paced Story of a Waitress And a Cat who must Fight a Girl in Australia	2006	1	\N	6	2.99	107	28.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'australia':20 'cat':13 'fast':5 'fast-pac':4 'fight':16 'girl':18 'monster':1 'must':15 'pace':6 'spartacus':2 'stori':7 'waitress':10
593	MONTEREY LABYRINTH	A Awe-Inspiring Drama of a Monkey And a Composer who must Escape a Feminist in A U-Boat	2006	1	\N	6	0.99	158	13.99	G	2006-02-15 05:03:42	{Trailers,Commentaries}	'awe':5 'awe-inspir':4 'boat':23 'compos':13 'drama':7 'escap':16 'feminist':18 'inspir':6 'labyrinth':2 'monkey':10 'monterey':1 'must':15 'u':22 'u-boat':21
594	MONTEZUMA COMMAND	A Thrilling Reflection of a Waitress And a Butler who must Battle a Butler in A Jet Boat	2006	1	\N	6	0.99	126	22.99	NC-17	2006-02-15 05:03:42	{Trailers}	'battl':14 'boat':20 'butler':11,16 'command':2 'jet':19 'montezuma':1 'must':13 'reflect':5 'thrill':4 'waitress':8
595	MOON BUNCH	A Beautiful Tale of a Astronaut And a Mad Cow who must Challenge a Cat in A Baloon Factory	2006	1	\N	7	0.99	83	20.99	PG	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'astronaut':8 'baloon':20 'beauti':4 'bunch':2 'cat':17 'challeng':15 'cow':12 'factori':21 'mad':11 'moon':1 'must':14 'tale':5
596	MOONSHINE CABIN	A Thoughtful Display of a Astronaut And a Feminist who must Chase a Frisbee in A Jet Boat	2006	1	\N	4	4.99	171	25.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'astronaut':8 'boat':20 'cabin':2 'chase':14 'display':5 'feminist':11 'frisbe':16 'jet':19 'moonshin':1 'must':13 'thought':4
597	MOONWALKER FOOL	A Epic Drama of a Feminist And a Pioneer who must Sink a Composer in New Orleans	2006	1	\N	5	4.99	184	12.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'compos':16 'drama':5 'epic':4 'feminist':8 'fool':2 'moonwalk':1 'must':13 'new':18 'orlean':19 'pioneer':11 'sink':14
598	MOSQUITO ARMAGEDDON	A Thoughtful Character Study of a Waitress And a Feminist who must Build a Teacher in Ancient Japan	2006	1	\N	6	0.99	57	22.99	G	2006-02-15 05:03:42	{Trailers}	'ancient':19 'armageddon':2 'build':15 'charact':5 'feminist':12 'japan':20 'mosquito':1 'must':14 'studi':6 'teacher':17 'thought':4 'waitress':9
599	MOTHER OLEANDER	A Boring Tale of a Husband And a Boy who must Fight a Squirrel in Ancient China	2006	1	\N	3	0.99	103	20.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'ancient':18 'bore':4 'boy':11 'china':19 'fight':14 'husband':8 'mother':1 'must':13 'oleand':2 'squirrel':16 'tale':5
600	MOTIONS DETAILS	A Awe-Inspiring Reflection of a Dog And a Student who must Kill a Car in An Abandoned Fun House	2006	1	\N	5	0.99	166	16.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'abandon':21 'awe':5 'awe-inspir':4 'car':18 'detail':2 'dog':10 'fun':22 'hous':23 'inspir':6 'kill':16 'motion':1 'must':15 'reflect':7 'student':13
601	MOULIN WAKE	A Astounding Story of a Forensic Psychologist And a Cat who must Battle a Teacher in An Abandoned Mine Shaft	2006	1	\N	4	0.99	79	20.99	PG-13	2006-02-15 05:03:42	{Trailers}	'abandon':20 'astound':4 'battl':15 'cat':12 'forens':8 'mine':21 'moulin':1 'must':14 'psychologist':9 'shaft':22 'stori':5 'teacher':17 'wake':2
602	MOURNING PURPLE	A Lacklusture Display of a Waitress And a Lumberjack who must Chase a Pioneer in New Orleans	2006	1	\N	5	0.99	146	14.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'chase':14 'display':5 'lacklustur':4 'lumberjack':11 'mourn':1 'must':13 'new':18 'orlean':19 'pioneer':16 'purpl':2 'waitress':8
603	MOVIE SHAKESPEARE	A Insightful Display of a Database Administrator And a Student who must Build a Hunter in Berlin	2006	1	\N	6	4.99	53	27.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'administr':9 'berlin':19 'build':15 'databas':8 'display':5 'hunter':17 'insight':4 'movi':1 'must':14 'shakespear':2 'student':12
604	MULAN MOON	A Emotional Saga of a Womanizer And a Pioneer who must Overcome a Dentist in A Baloon	2006	1	\N	4	0.99	160	10.99	G	2006-02-15 05:03:42	{"Behind the Scenes"}	'baloon':19 'dentist':16 'emot':4 'moon':2 'mulan':1 'must':13 'overcom':14 'pioneer':11 'saga':5 'woman':8
605	MULHOLLAND BEAST	A Awe-Inspiring Display of a Husband And a Squirrel who must Battle a Sumo Wrestler in A Jet Boat	2006	1	\N	7	2.99	157	13.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'awe':5 'awe-inspir':4 'battl':16 'beast':2 'boat':23 'display':7 'husband':10 'inspir':6 'jet':22 'mulholland':1 'must':15 'squirrel':13 'sumo':18 'wrestler':19
606	MUMMY CREATURES	A Fateful Character Study of a Crocodile And a Monkey who must Meet a Dentist in Australia	2006	1	\N	3	0.99	160	15.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'australia':19 'charact':5 'creatur':2 'crocodil':9 'dentist':17 'fate':4 'meet':15 'monkey':12 'mummi':1 'must':14 'studi':6
607	MUPPET MILE	A Lacklusture Story of a Madman And a Teacher who must Kill a Frisbee in The Gulf of Mexico	2006	1	\N	5	4.99	50	18.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'frisbe':16 'gulf':19 'kill':14 'lacklustur':4 'madman':8 'mexico':21 'mile':2 'muppet':1 'must':13 'stori':5 'teacher':11
608	MURDER ANTITRUST	A Brilliant Yarn of a Car And a Database Administrator who must Escape a Boy in A MySQL Convention	2006	1	\N	6	2.99	166	11.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'administr':12 'antitrust':2 'boy':17 'brilliant':4 'car':8 'convent':21 'databas':11 'escap':15 'murder':1 'must':14 'mysql':20 'yarn':5
609	MUSCLE BRIGHT	A Stunning Panorama of a Sumo Wrestler And a Husband who must Redeem a Madman in Ancient India	2006	1	\N	7	2.99	185	23.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'ancient':19 'bright':2 'husband':12 'india':20 'madman':17 'muscl':1 'must':14 'panorama':5 'redeem':15 'stun':4 'sumo':8 'wrestler':9
610	MUSIC BOONDOCK	A Thrilling Tale of a Butler And a Astronaut who must Battle a Explorer in The First Manned Space Station	2006	1	\N	7	0.99	129	17.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'astronaut':11 'battl':14 'boondock':2 'butler':8 'explor':16 'first':19 'man':20 'music':1 'must':13 'space':21 'station':22 'tale':5 'thrill':4
611	MUSKETEERS WAIT	A Touching Yarn of a Student And a Moose who must Fight a Mad Cow in Australia	2006	1	\N	7	4.99	73	17.99	PG	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'australia':19 'cow':17 'fight':14 'mad':16 'moos':11 'musket':1 'must':13 'student':8 'touch':4 'wait':2 'yarn':5
612	MUSSOLINI SPOILERS	A Thrilling Display of a Boat And a Monkey who must Meet a Composer in Ancient China	2006	1	\N	6	2.99	180	10.99	G	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'ancient':18 'boat':8 'china':19 'compos':16 'display':5 'meet':14 'monkey':11 'mussolini':1 'must':13 'spoiler':2 'thrill':4
613	MYSTIC TRUMAN	A Epic Yarn of a Teacher And a Hunter who must Outgun a Explorer in Soviet Georgia	2006	1	\N	5	0.99	92	19.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'epic':4 'explor':16 'georgia':19 'hunter':11 'must':13 'mystic':1 'outgun':14 'soviet':18 'teacher':8 'truman':2 'yarn':5
614	NAME DETECTIVE	A Touching Saga of a Sumo Wrestler And a Cat who must Pursue a Mad Scientist in Nigeria	2006	1	\N	5	4.99	178	11.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'cat':12 'detect':2 'mad':17 'must':14 'name':1 'nigeria':20 'pursu':15 'saga':5 'scientist':18 'sumo':8 'touch':4 'wrestler':9
615	NASH CHOCOLAT	A Epic Reflection of a Monkey And a Mad Cow who must Kill a Forensic Psychologist in An Abandoned Mine Shaft	2006	1	\N	6	2.99	180	21.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'abandon':21 'chocolat':2 'cow':12 'epic':4 'forens':17 'kill':15 'mad':11 'mine':22 'monkey':8 'must':14 'nash':1 'psychologist':18 'reflect':5 'shaft':23
616	NATIONAL STORY	A Taut Epistle of a Mad Scientist And a Girl who must Escape a Monkey in California	2006	1	\N	4	2.99	92	19.99	NC-17	2006-02-15 05:03:42	{Trailers}	'california':19 'epistl':5 'escap':15 'girl':12 'mad':8 'monkey':17 'must':14 'nation':1 'scientist':9 'stori':2 'taut':4
617	NATURAL STOCK	A Fast-Paced Story of a Sumo Wrestler And a Girl who must Defeat a Car in A Baloon Factory	2006	1	\N	4	0.99	50	24.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'baloon':22 'car':19 'defeat':17 'factori':23 'fast':5 'fast-pac':4 'girl':14 'must':16 'natur':1 'pace':6 'stock':2 'stori':7 'sumo':10 'wrestler':11
618	NECKLACE OUTBREAK	A Astounding Epistle of a Database Administrator And a Mad Scientist who must Pursue a Cat in California	2006	1	\N	3	0.99	132	21.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'administr':9 'astound':4 'california':20 'cat':18 'databas':8 'epistl':5 'mad':12 'must':15 'necklac':1 'outbreak':2 'pursu':16 'scientist':13
619	NEIGHBORS CHARADE	A Fanciful Reflection of a Crocodile And a Astronaut who must Outrace a Feminist in An Abandoned Amusement Park	2006	1	\N	3	0.99	161	20.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'abandon':19 'amus':20 'astronaut':11 'charad':2 'crocodil':8 'fanci':4 'feminist':16 'must':13 'neighbor':1 'outrac':14 'park':21 'reflect':5
620	NEMO CAMPUS	A Lacklusture Reflection of a Monkey And a Squirrel who must Outrace a Womanizer in A Manhattan Penthouse	2006	1	\N	5	2.99	131	23.99	NC-17	2006-02-15 05:03:42	{Trailers}	'campus':2 'lacklustur':4 'manhattan':19 'monkey':8 'must':13 'nemo':1 'outrac':14 'penthous':20 'reflect':5 'squirrel':11 'woman':16
621	NETWORK PEAK	A Unbelieveable Reflection of a Butler And a Boat who must Outgun a Mad Scientist in California	2006	1	\N	5	2.99	75	23.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'boat':11 'butler':8 'california':19 'mad':16 'must':13 'network':1 'outgun':14 'peak':2 'reflect':5 'scientist':17 'unbeliev':4
622	NEWSIES STORY	A Action-Packed Character Study of a Dog And a Lumberjack who must Outrace a Moose in The Gulf of Mexico	2006	1	\N	4	0.99	159	25.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'action':5 'action-pack':4 'charact':7 'dog':11 'gulf':22 'lumberjack':14 'mexico':24 'moos':19 'must':16 'newsi':1 'outrac':17 'pack':6 'stori':2 'studi':8
623	NEWTON LABYRINTH	A Intrepid Character Study of a Moose And a Waitress who must Find a A Shark in Ancient India	2006	1	\N	4	0.99	75	9.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'ancient':20 'charact':5 'find':15 'india':21 'intrepid':4 'labyrinth':2 'moos':9 'must':14 'newton':1 'shark':18 'studi':6 'waitress':12
624	NIGHTMARE CHILL	A Brilliant Display of a Robot And a Butler who must Fight a Waitress in An Abandoned Mine Shaft	2006	1	\N	3	4.99	149	25.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'abandon':19 'brilliant':4 'butler':11 'chill':2 'display':5 'fight':14 'mine':20 'must':13 'nightmar':1 'robot':8 'shaft':21 'waitress':16
625	NONE SPIKING	A Boring Reflection of a Secret Agent And a Astronaut who must Face a Composer in A Manhattan Penthouse	2006	1	\N	3	0.99	83	18.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries}	'agent':9 'astronaut':12 'bore':4 'compos':17 'face':15 'manhattan':20 'must':14 'none':1 'penthous':21 'reflect':5 'secret':8 'spike':2
626	NOON PAPI	A Unbelieveable Character Study of a Mad Scientist And a Astronaut who must Find a Pioneer in A Manhattan Penthouse	2006	1	\N	5	2.99	57	12.99	G	2006-02-15 05:03:42	{"Behind the Scenes"}	'astronaut':13 'charact':5 'find':16 'mad':9 'manhattan':21 'must':15 'noon':1 'papi':2 'penthous':22 'pioneer':18 'scientist':10 'studi':6 'unbeliev':4
627	NORTH TEQUILA	A Beautiful Character Study of a Mad Cow And a Robot who must Reach a Womanizer in New Orleans	2006	1	\N	4	4.99	67	9.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'beauti':4 'charact':5 'cow':10 'mad':9 'must':15 'new':20 'north':1 'orlean':21 'reach':16 'robot':13 'studi':6 'tequila':2 'woman':18
628	NORTHWEST POLISH	A Boring Character Study of a Boy And a A Shark who must Outrace a Womanizer in The Outback	2006	1	\N	5	2.99	172	24.99	PG	2006-02-15 05:03:42	{Trailers}	'bore':4 'boy':9 'charact':5 'must':15 'northwest':1 'outback':21 'outrac':16 'polish':2 'shark':13 'studi':6 'woman':18
629	NOTORIOUS REUNION	A Amazing Epistle of a Woman And a Squirrel who must Fight a Hunter in A Baloon	2006	1	\N	7	0.99	128	9.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'amaz':4 'baloon':19 'epistl':5 'fight':14 'hunter':16 'must':13 'notori':1 'reunion':2 'squirrel':11 'woman':8
630	NOTTING SPEAKEASY	A Thoughtful Display of a Butler And a Womanizer who must Find a Waitress in The Canadian Rockies	2006	1	\N	7	0.99	48	19.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'butler':8 'canadian':19 'display':5 'find':14 'must':13 'not':1 'rocki':20 'speakeasi':2 'thought':4 'waitress':16 'woman':11
631	NOVOCAINE FLIGHT	A Fanciful Display of a Student And a Teacher who must Outgun a Crocodile in Nigeria	2006	1	\N	4	0.99	64	11.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'crocodil':16 'display':5 'fanci':4 'flight':2 'must':13 'nigeria':18 'novocain':1 'outgun':14 'student':8 'teacher':11
632	NUTS TIES	A Thoughtful Drama of a Explorer And a Womanizer who must Meet a Teacher in California	2006	1	\N	5	4.99	145	10.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'california':18 'drama':5 'explor':8 'meet':14 'must':13 'nut':1 'teacher':16 'thought':4 'tie':2 'woman':11
633	OCTOBER SUBMARINE	A Taut Epistle of a Monkey And a Boy who must Confront a Husband in A Jet Boat	2006	1	\N	6	4.99	54	10.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'boat':20 'boy':11 'confront':14 'epistl':5 'husband':16 'jet':19 'monkey':8 'must':13 'octob':1 'submarin':2 'taut':4
634	ODDS BOOGIE	A Thrilling Yarn of a Feminist And a Madman who must Battle a Hunter in Berlin	2006	1	\N	6	0.99	48	14.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'battl':14 'berlin':18 'boogi':2 'feminist':8 'hunter':16 'madman':11 'must':13 'odd':1 'thrill':4 'yarn':5
635	OKLAHOMA JUMANJI	A Thoughtful Drama of a Dentist And a Womanizer who must Meet a Husband in The Sahara Desert	2006	1	\N	7	0.99	58	15.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'dentist':8 'desert':20 'drama':5 'husband':16 'jumanji':2 'meet':14 'must':13 'oklahoma':1 'sahara':19 'thought':4 'woman':11
636	OLEANDER CLUE	A Boring Story of a Teacher And a Monkey who must Succumb a Forensic Psychologist in A Jet Boat	2006	1	\N	5	0.99	161	12.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'boat':21 'bore':4 'clue':2 'forens':16 'jet':20 'monkey':11 'must':13 'oleand':1 'psychologist':17 'stori':5 'succumb':14 'teacher':8
637	OPEN AFRICAN	A Lacklusture Drama of a Secret Agent And a Explorer who must Discover a Car in A U-Boat	2006	1	\N	7	4.99	131	16.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'african':2 'agent':9 'boat':22 'car':17 'discov':15 'drama':5 'explor':12 'lacklustur':4 'must':14 'open':1 'secret':8 'u':21 'u-boat':20
638	OPERATION OPERATION	A Intrepid Character Study of a Man And a Frisbee who must Overcome a Madman in Ancient China	2006	1	\N	7	2.99	156	23.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'ancient':19 'charact':5 'china':20 'frisbe':12 'intrepid':4 'madman':17 'man':9 'must':14 'oper':1,2 'overcom':15 'studi':6
639	OPPOSITE NECKLACE	A Fateful Epistle of a Crocodile And a Moose who must Kill a Explorer in Nigeria	2006	1	\N	7	4.99	92	9.99	PG	2006-02-15 05:03:42	{"Deleted Scenes"}	'crocodil':8 'epistl':5 'explor':16 'fate':4 'kill':14 'moos':11 'must':13 'necklac':2 'nigeria':18 'opposit':1
640	OPUS ICE	A Fast-Paced Drama of a Hunter And a Boy who must Discover a Feminist in The Sahara Desert	2006	1	\N	5	4.99	102	21.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'boy':13 'desert':22 'discov':16 'drama':7 'fast':5 'fast-pac':4 'feminist':18 'hunter':10 'ice':2 'must':15 'opus':1 'pace':6 'sahara':21
641	ORANGE GRAPES	A Astounding Documentary of a Butler And a Womanizer who must Face a Dog in A U-Boat	2006	1	\N	4	0.99	76	21.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'astound':4 'boat':21 'butler':8 'documentari':5 'dog':16 'face':14 'grape':2 'must':13 'orang':1 'u':20 'u-boat':19 'woman':11
642	ORDER BETRAYED	A Amazing Saga of a Dog And a A Shark who must Challenge a Cat in The Sahara Desert	2006	1	\N	7	2.99	120	13.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'amaz':4 'betray':2 'cat':17 'challeng':15 'desert':21 'dog':8 'must':14 'order':1 'saga':5 'sahara':20 'shark':12
643	ORIENT CLOSER	A Astounding Epistle of a Technical Writer And a Teacher who must Fight a Squirrel in The Sahara Desert	2006	1	\N	3	2.99	118	22.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'astound':4 'closer':2 'desert':21 'epistl':5 'fight':15 'must':14 'orient':1 'sahara':20 'squirrel':17 'teacher':12 'technic':8 'writer':9
644	OSCAR GOLD	A Insightful Tale of a Database Administrator And a Dog who must Face a Madman in Soviet Georgia	2006	1	\N	7	2.99	115	29.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'administr':9 'databas':8 'dog':12 'face':15 'georgia':20 'gold':2 'insight':4 'madman':17 'must':14 'oscar':1 'soviet':19 'tale':5
645	OTHERS SOUP	A Lacklusture Documentary of a Mad Cow And a Madman who must Sink a Moose in The Gulf of Mexico	2006	1	\N	7	2.99	118	18.99	PG	2006-02-15 05:03:42	{"Deleted Scenes"}	'cow':9 'documentari':5 'gulf':20 'lacklustur':4 'mad':8 'madman':12 'mexico':22 'moos':17 'must':14 'other':1 'sink':15 'soup':2
646	OUTBREAK DIVINE	A Unbelieveable Yarn of a Database Administrator And a Woman who must Succumb a A Shark in A U-Boat	2006	1	\N	6	0.99	169	12.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'administr':9 'boat':23 'databas':8 'divin':2 'must':14 'outbreak':1 'shark':18 'succumb':15 'u':22 'u-boat':21 'unbeliev':4 'woman':12 'yarn':5
647	OUTFIELD MASSACRE	A Thoughtful Drama of a Husband And a Secret Agent who must Pursue a Database Administrator in Ancient India	2006	1	\N	4	0.99	129	18.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'administr':18 'agent':12 'ancient':20 'databas':17 'drama':5 'husband':8 'india':21 'massacr':2 'must':14 'outfield':1 'pursu':15 'secret':11 'thought':4
648	OUTLAW HANKY	A Thoughtful Story of a Astronaut And a Composer who must Conquer a Dog in The Sahara Desert	2006	1	\N	7	4.99	148	17.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'astronaut':8 'compos':11 'conquer':14 'desert':20 'dog':16 'hanki':2 'must':13 'outlaw':1 'sahara':19 'stori':5 'thought':4
649	OZ LIAISONS	A Epic Yarn of a Mad Scientist And a Cat who must Confront a Womanizer in A Baloon Factory	2006	1	\N	4	2.99	85	14.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'baloon':20 'cat':12 'confront':15 'epic':4 'factori':21 'liaison':2 'mad':8 'must':14 'oz':1 'scientist':9 'woman':17 'yarn':5
650	PACIFIC AMISTAD	A Thrilling Yarn of a Dog And a Moose who must Kill a Pastry Chef in A Manhattan Penthouse	2006	1	\N	3	0.99	144	27.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'amistad':2 'chef':17 'dog':8 'kill':14 'manhattan':20 'moos':11 'must':13 'pacif':1 'pastri':16 'penthous':21 'thrill':4 'yarn':5
651	PACKER MADIGAN	A Epic Display of a Sumo Wrestler And a Forensic Psychologist who must Build a Woman in An Abandoned Amusement Park	2006	1	\N	3	0.99	84	20.99	PG-13	2006-02-15 05:03:42	{Trailers}	'abandon':21 'amus':22 'build':16 'display':5 'epic':4 'forens':12 'madigan':2 'must':15 'packer':1 'park':23 'psychologist':13 'sumo':8 'woman':18 'wrestler':9
652	PAJAMA JAWBREAKER	A Emotional Drama of a Boy And a Technical Writer who must Redeem a Sumo Wrestler in California	2006	1	\N	3	0.99	126	14.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'boy':8 'california':20 'drama':5 'emot':4 'jawbreak':2 'must':14 'pajama':1 'redeem':15 'sumo':17 'technic':11 'wrestler':18 'writer':12
653	PANIC CLUB	A Fanciful Display of a Teacher And a Crocodile who must Succumb a Girl in A Baloon	2006	1	\N	3	4.99	102	15.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'baloon':19 'club':2 'crocodil':11 'display':5 'fanci':4 'girl':16 'must':13 'panic':1 'succumb':14 'teacher':8
654	PANKY SUBMARINE	A Touching Documentary of a Dentist And a Sumo Wrestler who must Overcome a Boy in The Gulf of Mexico	2006	1	\N	4	4.99	93	19.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'boy':17 'dentist':8 'documentari':5 'gulf':20 'mexico':22 'must':14 'overcom':15 'panki':1 'submarin':2 'sumo':11 'touch':4 'wrestler':12
655	PANTHER REDS	A Brilliant Panorama of a Moose And a Man who must Reach a Teacher in The Gulf of Mexico	2006	1	\N	5	4.99	109	22.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'brilliant':4 'gulf':19 'man':11 'mexico':21 'moos':8 'must':13 'panorama':5 'panther':1 'reach':14 'red':2 'teacher':16
656	PAPI NECKLACE	A Fanciful Display of a Car And a Monkey who must Escape a Squirrel in Ancient Japan	2006	1	\N	3	0.99	128	9.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'ancient':18 'car':8 'display':5 'escap':14 'fanci':4 'japan':19 'monkey':11 'must':13 'necklac':2 'papi':1 'squirrel':16
657	PARADISE SABRINA	A Intrepid Yarn of a Car And a Moose who must Outrace a Crocodile in A Manhattan Penthouse	2006	1	\N	5	2.99	48	12.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'car':8 'crocodil':16 'intrepid':4 'manhattan':19 'moos':11 'must':13 'outrac':14 'paradis':1 'penthous':20 'sabrina':2 'yarn':5
658	PARIS WEEKEND	A Intrepid Story of a Squirrel And a Crocodile who must Defeat a Monkey in The Outback	2006	1	\N	7	2.99	121	19.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'crocodil':11 'defeat':14 'intrepid':4 'monkey':16 'must':13 'outback':19 'pari':1 'squirrel':8 'stori':5 'weekend':2
659	PARK CITIZEN	A Taut Epistle of a Sumo Wrestler And a Girl who must Face a Husband in Ancient Japan	2006	1	\N	3	4.99	109	14.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'ancient':19 'citizen':2 'epistl':5 'face':15 'girl':12 'husband':17 'japan':20 'must':14 'park':1 'sumo':8 'taut':4 'wrestler':9
660	PARTY KNOCK	A Fateful Display of a Technical Writer And a Butler who must Battle a Sumo Wrestler in An Abandoned Mine Shaft	2006	1	\N	7	2.99	107	11.99	PG	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'abandon':21 'battl':15 'butler':12 'display':5 'fate':4 'knock':2 'mine':22 'must':14 'parti':1 'shaft':23 'sumo':17 'technic':8 'wrestler':18 'writer':9
661	PAST SUICIDES	A Intrepid Tale of a Madman And a Astronaut who must Challenge a Hunter in A Monastery	2006	1	\N	5	4.99	157	17.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'astronaut':11 'challeng':14 'hunter':16 'intrepid':4 'madman':8 'monasteri':19 'must':13 'past':1 'suicid':2 'tale':5
662	PATHS CONTROL	A Astounding Documentary of a Butler And a Cat who must Find a Frisbee in Ancient China	2006	1	\N	3	4.99	118	9.99	PG	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'ancient':18 'astound':4 'butler':8 'cat':11 'china':19 'control':2 'documentari':5 'find':14 'frisbe':16 'must':13 'path':1
663	PATIENT SISTER	A Emotional Epistle of a Squirrel And a Robot who must Confront a Lumberjack in Soviet Georgia	2006	1	\N	7	0.99	99	29.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries}	'confront':14 'emot':4 'epistl':5 'georgia':19 'lumberjack':16 'must':13 'patient':1 'robot':11 'sister':2 'soviet':18 'squirrel':8
664	PATRIOT ROMAN	A Taut Saga of a Robot And a Database Administrator who must Challenge a Astronaut in California	2006	1	\N	6	2.99	65	12.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'administr':12 'astronaut':17 'california':19 'challeng':15 'databas':11 'must':14 'patriot':1 'robot':8 'roman':2 'saga':5 'taut':4
665	PATTON INTERVIEW	A Thrilling Documentary of a Composer And a Secret Agent who must Succumb a Cat in Berlin	2006	1	\N	4	2.99	175	22.99	PG	2006-02-15 05:03:42	{Commentaries}	'agent':12 'berlin':19 'cat':17 'compos':8 'documentari':5 'interview':2 'must':14 'patton':1 'secret':11 'succumb':15 'thrill':4
666	PAYCHECK WAIT	A Awe-Inspiring Reflection of a Boy And a Man who must Discover a Moose in The Sahara Desert	2006	1	\N	4	4.99	145	27.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'awe':5 'awe-inspir':4 'boy':10 'desert':22 'discov':16 'inspir':6 'man':13 'moos':18 'must':15 'paycheck':1 'reflect':7 'sahara':21 'wait':2
667	PEACH INNOCENT	A Action-Packed Drama of a Monkey And a Dentist who must Chase a Butler in Berlin	2006	1	\N	3	2.99	160	20.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'action':5 'action-pack':4 'berlin':20 'butler':18 'chase':16 'dentist':13 'drama':7 'innoc':2 'monkey':10 'must':15 'pack':6 'peach':1
668	PEAK FOREVER	A Insightful Reflection of a Boat And a Secret Agent who must Vanquish a Astronaut in An Abandoned Mine Shaft	2006	1	\N	7	4.99	80	25.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':20 'agent':12 'astronaut':17 'boat':8 'forev':2 'insight':4 'mine':21 'must':14 'peak':1 'reflect':5 'secret':11 'shaft':22 'vanquish':15
669	PEARL DESTINY	A Lacklusture Yarn of a Astronaut And a Pastry Chef who must Sink a Dog in A U-Boat	2006	1	\N	3	2.99	74	10.99	NC-17	2006-02-15 05:03:42	{Trailers}	'astronaut':8 'boat':22 'chef':12 'destini':2 'dog':17 'lacklustur':4 'must':14 'pastri':11 'pearl':1 'sink':15 'u':21 'u-boat':20 'yarn':5
670	PELICAN COMFORTS	A Epic Documentary of a Boy And a Monkey who must Pursue a Astronaut in Berlin	2006	1	\N	4	4.99	48	17.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'astronaut':16 'berlin':18 'boy':8 'comfort':2 'documentari':5 'epic':4 'monkey':11 'must':13 'pelican':1 'pursu':14
671	PERDITION FARGO	A Fast-Paced Story of a Car And a Cat who must Outgun a Hunter in Berlin	2006	1	\N	7	4.99	99	27.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'berlin':20 'car':10 'cat':13 'fargo':2 'fast':5 'fast-pac':4 'hunter':18 'must':15 'outgun':16 'pace':6 'perdit':1 'stori':7
672	PERFECT GROOVE	A Thrilling Yarn of a Dog And a Dog who must Build a Husband in A Baloon	2006	1	\N	7	2.99	82	17.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'baloon':19 'build':14 'dog':8,11 'groov':2 'husband':16 'must':13 'perfect':1 'thrill':4 'yarn':5
673	PERSONAL LADYBUGS	A Epic Saga of a Hunter And a Technical Writer who must Conquer a Cat in Ancient Japan	2006	1	\N	3	0.99	118	19.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'ancient':19 'cat':17 'conquer':15 'epic':4 'hunter':8 'japan':20 'ladybug':2 'must':14 'person':1 'saga':5 'technic':11 'writer':12
674	PET HAUNTING	A Unbelieveable Reflection of a Explorer And a Boat who must Conquer a Woman in California	2006	1	\N	3	0.99	99	11.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'boat':11 'california':18 'conquer':14 'explor':8 'haunt':2 'must':13 'pet':1 'reflect':5 'unbeliev':4 'woman':16
675	PHANTOM GLORY	A Beautiful Documentary of a Astronaut And a Crocodile who must Discover a Madman in A Monastery	2006	1	\N	6	2.99	60	17.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'astronaut':8 'beauti':4 'crocodil':11 'discov':14 'documentari':5 'glori':2 'madman':16 'monasteri':19 'must':13 'phantom':1
676	PHILADELPHIA WIFE	A Taut Yarn of a Hunter And a Astronaut who must Conquer a Database Administrator in The Sahara Desert	2006	1	\N	7	4.99	137	16.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'administr':17 'astronaut':11 'conquer':14 'databas':16 'desert':21 'hunter':8 'must':13 'philadelphia':1 'sahara':20 'taut':4 'wife':2 'yarn':5
677	PIANIST OUTFIELD	A Intrepid Story of a Boy And a Technical Writer who must Pursue a Lumberjack in A Monastery	2006	1	\N	6	0.99	136	25.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'boy':8 'intrepid':4 'lumberjack':17 'monasteri':20 'must':14 'outfield':2 'pianist':1 'pursu':15 'stori':5 'technic':11 'writer':12
678	PICKUP DRIVING	A Touching Documentary of a Husband And a Boat who must Meet a Pastry Chef in A Baloon Factory	2006	1	\N	3	2.99	77	23.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'baloon':20 'boat':11 'chef':17 'documentari':5 'drive':2 'factori':21 'husband':8 'meet':14 'must':13 'pastri':16 'pickup':1 'touch':4
679	PILOT HOOSIERS	A Awe-Inspiring Reflection of a Crocodile And a Sumo Wrestler who must Meet a Forensic Psychologist in An Abandoned Mine Shaft	2006	1	\N	6	2.99	50	17.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'abandon':23 'awe':5 'awe-inspir':4 'crocodil':10 'forens':19 'hoosier':2 'inspir':6 'meet':17 'mine':24 'must':16 'pilot':1 'psychologist':20 'reflect':7 'shaft':25 'sumo':13 'wrestler':14
680	PINOCCHIO SIMON	A Action-Packed Reflection of a Mad Scientist And a A Shark who must Find a Feminist in California	2006	1	\N	4	4.99	103	21.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'action':5 'action-pack':4 'california':22 'feminist':20 'find':18 'mad':10 'must':17 'pack':6 'pinocchio':1 'reflect':7 'scientist':11 'shark':15 'simon':2
681	PIRATES ROXANNE	A Stunning Drama of a Woman And a Lumberjack who must Overcome a A Shark in The Canadian Rockies	2006	1	\N	4	0.99	100	20.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'canadian':20 'drama':5 'lumberjack':11 'must':13 'overcom':14 'pirat':1 'rocki':21 'roxann':2 'shark':17 'stun':4 'woman':8
682	PITTSBURGH HUNCHBACK	A Thrilling Epistle of a Boy And a Boat who must Find a Student in Soviet Georgia	2006	1	\N	4	4.99	134	17.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'boat':11 'boy':8 'epistl':5 'find':14 'georgia':19 'hunchback':2 'must':13 'pittsburgh':1 'soviet':18 'student':16 'thrill':4
683	PITY BOUND	A Boring Panorama of a Feminist And a Moose who must Defeat a Database Administrator in Nigeria	2006	1	\N	5	4.99	60	19.99	NC-17	2006-02-15 05:03:42	{Commentaries}	'administr':17 'bore':4 'bound':2 'databas':16 'defeat':14 'feminist':8 'moos':11 'must':13 'nigeria':19 'panorama':5 'piti':1
684	PIZZA JUMANJI	A Epic Saga of a Cat And a Squirrel who must Outgun a Robot in A U-Boat	2006	1	\N	4	2.99	173	11.99	NC-17	2006-02-15 05:03:42	{Commentaries}	'boat':21 'cat':8 'epic':4 'jumanji':2 'must':13 'outgun':14 'pizza':1 'robot':16 'saga':5 'squirrel':11 'u':20 'u-boat':19
685	PLATOON INSTINCT	A Thrilling Panorama of a Man And a Woman who must Reach a Woman in Australia	2006	1	\N	6	4.99	132	10.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'australia':18 'instinct':2 'man':8 'must':13 'panorama':5 'platoon':1 'reach':14 'thrill':4 'woman':11,16
686	PLUTO OLEANDER	A Action-Packed Reflection of a Car And a Moose who must Outgun a Car in A Shark Tank	2006	1	\N	5	4.99	84	9.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'action':5 'action-pack':4 'car':10,18 'moos':13 'must':15 'oleand':2 'outgun':16 'pack':6 'pluto':1 'reflect':7 'shark':21 'tank':22
687	POCUS PULP	A Intrepid Yarn of a Frisbee And a Dog who must Build a Astronaut in A Baloon Factory	2006	1	\N	6	0.99	138	15.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'astronaut':16 'baloon':19 'build':14 'dog':11 'factori':20 'frisbe':8 'intrepid':4 'must':13 'pocus':1 'pulp':2 'yarn':5
688	POLISH BROOKLYN	A Boring Character Study of a Database Administrator And a Lumberjack who must Reach a Madman in The Outback	2006	1	\N	6	0.99	61	12.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'administr':10 'bore':4 'brooklyn':2 'charact':5 'databas':9 'lumberjack':13 'madman':18 'must':15 'outback':21 'polish':1 'reach':16 'studi':6
689	POLLOCK DELIVERANCE	A Intrepid Story of a Madman And a Frisbee who must Outgun a Boat in The Sahara Desert	2006	1	\N	5	2.99	137	14.99	PG	2006-02-15 05:03:42	{Commentaries}	'boat':16 'deliver':2 'desert':20 'frisbe':11 'intrepid':4 'madman':8 'must':13 'outgun':14 'pollock':1 'sahara':19 'stori':5
690	POND SEATTLE	A Stunning Drama of a Teacher And a Boat who must Battle a Feminist in Ancient China	2006	1	\N	7	2.99	185	25.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'ancient':18 'battl':14 'boat':11 'china':19 'drama':5 'feminist':16 'must':13 'pond':1 'seattl':2 'stun':4 'teacher':8
691	POSEIDON FOREVER	A Thoughtful Epistle of a Womanizer And a Monkey who must Vanquish a Dentist in A Monastery	2006	1	\N	6	4.99	159	29.99	PG-13	2006-02-15 05:03:42	{Commentaries}	'dentist':16 'epistl':5 'forev':2 'monasteri':19 'monkey':11 'must':13 'poseidon':1 'thought':4 'vanquish':14 'woman':8
692	POTLUCK MIXED	A Beautiful Story of a Dog And a Technical Writer who must Outgun a Student in A Baloon	2006	1	\N	3	2.99	179	10.99	G	2006-02-15 05:03:42	{"Behind the Scenes"}	'baloon':20 'beauti':4 'dog':8 'mix':2 'must':14 'outgun':15 'potluck':1 'stori':5 'student':17 'technic':11 'writer':12
693	POTTER CONNECTICUT	A Thrilling Epistle of a Frisbee And a Cat who must Fight a Technical Writer in Berlin	2006	1	\N	5	2.99	115	16.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'berlin':19 'cat':11 'connecticut':2 'epistl':5 'fight':14 'frisbe':8 'must':13 'potter':1 'technic':16 'thrill':4 'writer':17
694	PREJUDICE OLEANDER	A Epic Saga of a Boy And a Dentist who must Outrace a Madman in A U-Boat	2006	1	\N	6	4.99	98	15.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'boat':21 'boy':8 'dentist':11 'epic':4 'madman':16 'must':13 'oleand':2 'outrac':14 'prejudic':1 'saga':5 'u':20 'u-boat':19
695	PRESIDENT BANG	A Fateful Panorama of a Technical Writer And a Moose who must Battle a Robot in Soviet Georgia	2006	1	\N	6	4.99	144	12.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'bang':2 'battl':15 'fate':4 'georgia':20 'moos':12 'must':14 'panorama':5 'presid':1 'robot':17 'soviet':19 'technic':8 'writer':9
696	PRIDE ALAMO	A Thoughtful Drama of a A Shark And a Forensic Psychologist who must Vanquish a Student in Ancient India	2006	1	\N	6	0.99	114	20.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes"}	'alamo':2 'ancient':20 'drama':5 'forens':12 'india':21 'must':15 'pride':1 'psychologist':13 'shark':9 'student':18 'thought':4 'vanquish':16
697	PRIMARY GLASS	A Fateful Documentary of a Pastry Chef And a Butler who must Build a Dog in The Canadian Rockies	2006	1	\N	7	0.99	53	16.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'build':15 'butler':12 'canadian':20 'chef':9 'documentari':5 'dog':17 'fate':4 'glass':2 'must':14 'pastri':8 'primari':1 'rocki':21
698	PRINCESS GIANT	A Thrilling Yarn of a Pastry Chef And a Monkey who must Battle a Monkey in A Shark Tank	2006	1	\N	3	2.99	71	29.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'battl':15 'chef':9 'giant':2 'monkey':12,17 'must':14 'pastri':8 'princess':1 'shark':20 'tank':21 'thrill':4 'yarn':5
699	PRIVATE DROP	A Stunning Story of a Technical Writer And a Hunter who must Succumb a Secret Agent in A Baloon	2006	1	\N	7	4.99	106	26.99	PG	2006-02-15 05:03:42	{Trailers}	'agent':18 'baloon':21 'drop':2 'hunter':12 'must':14 'privat':1 'secret':17 'stori':5 'stun':4 'succumb':15 'technic':8 'writer':9
700	PRIX UNDEFEATED	A Stunning Saga of a Mad Scientist And a Boat who must Overcome a Dentist in Ancient China	2006	1	\N	4	2.99	115	13.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'ancient':19 'boat':12 'china':20 'dentist':17 'mad':8 'must':14 'overcom':15 'prix':1 'saga':5 'scientist':9 'stun':4 'undef':2
701	PSYCHO SHRUNK	A Amazing Panorama of a Crocodile And a Explorer who must Fight a Husband in Nigeria	2006	1	\N	5	2.99	155	11.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'amaz':4 'crocodil':8 'explor':11 'fight':14 'husband':16 'must':13 'nigeria':18 'panorama':5 'psycho':1 'shrunk':2
702	PULP BEVERLY	A Unbelieveable Display of a Dog And a Crocodile who must Outrace a Man in Nigeria	2006	1	\N	4	2.99	89	12.99	G	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'bever':2 'crocodil':11 'display':5 'dog':8 'man':16 'must':13 'nigeria':18 'outrac':14 'pulp':1 'unbeliev':4
703	PUNK DIVORCE	A Fast-Paced Tale of a Pastry Chef And a Boat who must Face a Frisbee in The Canadian Rockies	2006	1	\N	6	4.99	100	18.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'boat':14 'canadian':22 'chef':11 'divorc':2 'face':17 'fast':5 'fast-pac':4 'frisbe':19 'must':16 'pace':6 'pastri':10 'punk':1 'rocki':23 'tale':7
704	PURE RUNNER	A Thoughtful Documentary of a Student And a Madman who must Challenge a Squirrel in A Manhattan Penthouse	2006	1	\N	3	2.99	121	25.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'challeng':14 'documentari':5 'madman':11 'manhattan':19 'must':13 'penthous':20 'pure':1 'runner':2 'squirrel':16 'student':8 'thought':4
705	PURPLE MOVIE	A Boring Display of a Pastry Chef And a Sumo Wrestler who must Discover a Frisbee in An Abandoned Amusement Park	2006	1	\N	4	2.99	88	9.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'abandon':21 'amus':22 'bore':4 'chef':9 'discov':16 'display':5 'frisbe':18 'movi':2 'must':15 'park':23 'pastri':8 'purpl':1 'sumo':12 'wrestler':13
706	QUEEN LUKE	A Astounding Story of a Girl And a Boy who must Challenge a Composer in New Orleans	2006	1	\N	5	4.99	163	22.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'astound':4 'boy':11 'challeng':14 'compos':16 'girl':8 'luke':2 'must':13 'new':18 'orlean':19 'queen':1 'stori':5
707	QUEST MUSSOLINI	A Fateful Drama of a Husband And a Sumo Wrestler who must Battle a Pastry Chef in A Baloon Factory	2006	1	\N	5	2.99	177	29.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'baloon':21 'battl':15 'chef':18 'drama':5 'factori':22 'fate':4 'husband':8 'mussolini':2 'must':14 'pastri':17 'quest':1 'sumo':11 'wrestler':12
708	QUILLS BULL	A Thoughtful Story of a Pioneer And a Woman who must Reach a Moose in Australia	2006	1	\N	4	4.99	112	19.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'australia':18 'bull':2 'moos':16 'must':13 'pioneer':8 'quill':1 'reach':14 'stori':5 'thought':4 'woman':11
709	RACER EGG	A Emotional Display of a Monkey And a Waitress who must Reach a Secret Agent in California	2006	1	\N	7	2.99	147	19.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'agent':17 'california':19 'display':5 'egg':2 'emot':4 'monkey':8 'must':13 'racer':1 'reach':14 'secret':16 'waitress':11
710	RAGE GAMES	A Fast-Paced Saga of a Astronaut And a Secret Agent who must Escape a Hunter in An Abandoned Amusement Park	2006	1	\N	4	4.99	120	18.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'abandon':22 'agent':14 'amus':23 'astronaut':10 'escap':17 'fast':5 'fast-pac':4 'game':2 'hunter':19 'must':16 'pace':6 'park':24 'rage':1 'saga':7 'secret':13
711	RAGING AIRPLANE	A Astounding Display of a Secret Agent And a Technical Writer who must Escape a Mad Scientist in A Jet Boat	2006	1	\N	4	4.99	154	18.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'agent':9 'airplan':2 'astound':4 'boat':23 'display':5 'escap':16 'jet':22 'mad':18 'must':15 'rage':1 'scientist':19 'secret':8 'technic':12 'writer':13
712	RAIDERS ANTITRUST	A Amazing Drama of a Teacher And a Feminist who must Meet a Woman in The First Manned Space Station	2006	1	\N	4	0.99	82	11.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'amaz':4 'antitrust':2 'drama':5 'feminist':11 'first':19 'man':20 'meet':14 'must':13 'raider':1 'space':21 'station':22 'teacher':8 'woman':16
713	RAINBOW SHOCK	A Action-Packed Story of a Hunter And a Boy who must Discover a Lumberjack in Ancient India	2006	1	\N	3	4.99	74	14.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'action':5 'action-pack':4 'ancient':20 'boy':13 'discov':16 'hunter':10 'india':21 'lumberjack':18 'must':15 'pack':6 'rainbow':1 'shock':2 'stori':7
714	RANDOM GO	A Fateful Drama of a Frisbee And a Student who must Confront a Cat in A Shark Tank	2006	1	\N	6	2.99	73	29.99	NC-17	2006-02-15 05:03:42	{Trailers}	'cat':16 'confront':14 'drama':5 'fate':4 'frisbe':8 'go':2 'must':13 'random':1 'shark':19 'student':11 'tank':20
715	RANGE MOONWALKER	A Insightful Documentary of a Hunter And a Dentist who must Confront a Crocodile in A Baloon	2006	1	\N	3	4.99	147	25.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'baloon':19 'confront':14 'crocodil':16 'dentist':11 'documentari':5 'hunter':8 'insight':4 'moonwalk':2 'must':13 'rang':1
716	REAP UNFAITHFUL	A Thrilling Epistle of a Composer And a Sumo Wrestler who must Challenge a Mad Cow in A MySQL Convention	2006	1	\N	6	2.99	136	26.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'challeng':15 'compos':8 'convent':22 'cow':18 'epistl':5 'mad':17 'must':14 'mysql':21 'reap':1 'sumo':11 'thrill':4 'unfaith':2 'wrestler':12
717	REAR TRADING	A Awe-Inspiring Reflection of a Forensic Psychologist And a Secret Agent who must Succumb a Pastry Chef in Soviet Georgia	2006	1	\N	6	0.99	97	23.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'agent':15 'awe':5 'awe-inspir':4 'chef':21 'forens':10 'georgia':24 'inspir':6 'must':17 'pastri':20 'psychologist':11 'rear':1 'reflect':7 'secret':14 'soviet':23 'succumb':18 'trade':2
718	REBEL AIRPORT	A Intrepid Yarn of a Database Administrator And a Boat who must Outrace a Husband in Ancient India	2006	1	\N	7	0.99	73	24.99	G	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'administr':9 'airport':2 'ancient':19 'boat':12 'databas':8 'husband':17 'india':20 'intrepid':4 'must':14 'outrac':15 'rebel':1 'yarn':5
719	RECORDS ZORRO	A Amazing Drama of a Mad Scientist And a Composer who must Build a Husband in The Outback	2006	1	\N	7	4.99	182	11.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'amaz':4 'build':15 'compos':12 'drama':5 'husband':17 'mad':8 'must':14 'outback':20 'record':1 'scientist':9 'zorro':2
720	REDEMPTION COMFORTS	A Emotional Documentary of a Dentist And a Woman who must Battle a Mad Scientist in Ancient China	2006	1	\N	3	2.99	179	20.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'ancient':19 'battl':14 'china':20 'comfort':2 'dentist':8 'documentari':5 'emot':4 'mad':16 'must':13 'redempt':1 'scientist':17 'woman':11
721	REDS POCUS	A Lacklusture Yarn of a Sumo Wrestler And a Squirrel who must Redeem a Monkey in Soviet Georgia	2006	1	\N	7	4.99	182	23.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'georgia':20 'lacklustur':4 'monkey':17 'must':14 'pocus':2 'red':1 'redeem':15 'soviet':19 'squirrel':12 'sumo':8 'wrestler':9 'yarn':5
722	REEF SALUTE	A Action-Packed Saga of a Teacher And a Lumberjack who must Battle a Dentist in A Baloon	2006	1	\N	5	0.99	123	26.99	NC-17	2006-02-15 05:03:42	{"Behind the Scenes"}	'action':5 'action-pack':4 'baloon':21 'battl':16 'dentist':18 'lumberjack':13 'must':15 'pack':6 'reef':1 'saga':7 'salut':2 'teacher':10
723	REIGN GENTLEMEN	A Emotional Yarn of a Composer And a Man who must Escape a Butler in The Gulf of Mexico	2006	1	\N	3	2.99	82	29.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'butler':16 'compos':8 'emot':4 'escap':14 'gentlemen':2 'gulf':19 'man':11 'mexico':21 'must':13 'reign':1 'yarn':5
724	REMEMBER DIARY	A Insightful Tale of a Technical Writer And a Waitress who must Conquer a Monkey in Ancient India	2006	1	\N	5	2.99	110	15.99	R	2006-02-15 05:03:42	{Trailers,Commentaries}	'ancient':19 'conquer':15 'diari':2 'india':20 'insight':4 'monkey':17 'must':14 'rememb':1 'tale':5 'technic':8 'waitress':12 'writer':9
725	REQUIEM TYCOON	A Unbelieveable Character Study of a Cat And a Database Administrator who must Pursue a Teacher in A Monastery	2006	1	\N	6	4.99	167	25.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'administr':13 'cat':9 'charact':5 'databas':12 'monasteri':21 'must':15 'pursu':16 'requiem':1 'studi':6 'teacher':18 'tycoon':2 'unbeliev':4
726	RESERVOIR ADAPTATION	A Intrepid Drama of a Teacher And a Moose who must Kill a Car in California	2006	1	\N	7	2.99	61	29.99	PG-13	2006-02-15 05:03:42	{Commentaries}	'adapt':2 'california':18 'car':16 'drama':5 'intrepid':4 'kill':14 'moos':11 'must':13 'reservoir':1 'teacher':8
727	RESURRECTION SILVERADO	A Epic Yarn of a Robot And a Explorer who must Challenge a Girl in A MySQL Convention	2006	1	\N	6	0.99	117	12.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'challeng':14 'convent':20 'epic':4 'explor':11 'girl':16 'must':13 'mysql':19 'resurrect':1 'robot':8 'silverado':2 'yarn':5
728	REUNION WITCHES	A Unbelieveable Documentary of a Database Administrator And a Frisbee who must Redeem a Mad Scientist in A Baloon Factory	2006	1	\N	3	0.99	63	26.99	R	2006-02-15 05:03:42	{Commentaries}	'administr':9 'baloon':21 'databas':8 'documentari':5 'factori':22 'frisbe':12 'mad':17 'must':14 'redeem':15 'reunion':1 'scientist':18 'unbeliev':4 'witch':2
729	RIDER CADDYSHACK	A Taut Reflection of a Monkey And a Womanizer who must Chase a Moose in Nigeria	2006	1	\N	5	2.99	177	28.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'caddyshack':2 'chase':14 'monkey':8 'moos':16 'must':13 'nigeria':18 'reflect':5 'rider':1 'taut':4 'woman':11
730	RIDGEMONT SUBMARINE	A Unbelieveable Drama of a Waitress And a Composer who must Sink a Mad Cow in Ancient Japan	2006	1	\N	3	0.99	46	28.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'ancient':19 'compos':11 'cow':17 'drama':5 'japan':20 'mad':16 'must':13 'ridgemont':1 'sink':14 'submarin':2 'unbeliev':4 'waitress':8
731	RIGHT CRANES	A Fateful Character Study of a Boat And a Cat who must Find a Database Administrator in A Jet Boat	2006	1	\N	7	4.99	153	29.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'administr':18 'boat':9,22 'cat':12 'charact':5 'crane':2 'databas':17 'fate':4 'find':15 'jet':21 'must':14 'right':1 'studi':6
732	RINGS HEARTBREAKERS	A Amazing Yarn of a Sumo Wrestler And a Boat who must Conquer a Waitress in New Orleans	2006	1	\N	5	0.99	58	17.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'amaz':4 'boat':12 'conquer':15 'heartbreak':2 'must':14 'new':19 'orlean':20 'ring':1 'sumo':8 'waitress':17 'wrestler':9 'yarn':5
733	RIVER OUTLAW	A Thrilling Character Study of a Squirrel And a Lumberjack who must Face a Hunter in A MySQL Convention	2006	1	\N	4	0.99	149	29.99	PG-13	2006-02-15 05:03:42	{Commentaries}	'charact':5 'convent':21 'face':15 'hunter':17 'lumberjack':12 'must':14 'mysql':20 'outlaw':2 'river':1 'squirrel':9 'studi':6 'thrill':4
734	ROAD ROXANNE	A Boring Character Study of a Waitress And a Astronaut who must Fight a Crocodile in Ancient Japan	2006	1	\N	4	4.99	158	12.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'ancient':19 'astronaut':12 'bore':4 'charact':5 'crocodil':17 'fight':15 'japan':20 'must':14 'road':1 'roxann':2 'studi':6 'waitress':9
735	ROBBERS JOON	A Thoughtful Story of a Mad Scientist And a Waitress who must Confront a Forensic Psychologist in Soviet Georgia	2006	1	\N	7	2.99	102	26.99	PG-13	2006-02-15 05:03:42	{Commentaries}	'confront':15 'forens':17 'georgia':21 'joon':2 'mad':8 'must':14 'psychologist':18 'robber':1 'scientist':9 'soviet':20 'stori':5 'thought':4 'waitress':12
736	ROBBERY BRIGHT	A Taut Reflection of a Robot And a Squirrel who must Fight a Boat in Ancient Japan	2006	1	\N	4	0.99	134	21.99	R	2006-02-15 05:03:42	{Trailers}	'ancient':18 'boat':16 'bright':2 'fight':14 'japan':19 'must':13 'reflect':5 'robberi':1 'robot':8 'squirrel':11 'taut':4
737	ROCK INSTINCT	A Astounding Character Study of a Robot And a Moose who must Overcome a Astronaut in Ancient India	2006	1	\N	4	0.99	102	28.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'ancient':19 'astound':4 'astronaut':17 'charact':5 'india':20 'instinct':2 'moos':12 'must':14 'overcom':15 'robot':9 'rock':1 'studi':6
738	ROCKETEER MOTHER	A Awe-Inspiring Character Study of a Robot And a Sumo Wrestler who must Discover a Womanizer in A Shark Tank	2006	1	\N	3	0.99	178	27.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'awe':5 'awe-inspir':4 'charact':7 'discov':18 'inspir':6 'mother':2 'must':17 'robot':11 'rocket':1 'shark':23 'studi':8 'sumo':14 'tank':24 'woman':20 'wrestler':15
739	ROCKY WAR	A Fast-Paced Display of a Squirrel And a Explorer who must Outgun a Mad Scientist in Nigeria	2006	1	\N	4	4.99	145	17.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'display':7 'explor':13 'fast':5 'fast-pac':4 'mad':18 'must':15 'nigeria':21 'outgun':16 'pace':6 'rocki':1 'scientist':19 'squirrel':10 'war':2
740	ROLLERCOASTER BRINGING	A Beautiful Drama of a Robot And a Lumberjack who must Discover a Technical Writer in A Shark Tank	2006	1	\N	5	2.99	153	13.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'beauti':4 'bring':2 'discov':14 'drama':5 'lumberjack':11 'must':13 'robot':8 'rollercoast':1 'shark':20 'tank':21 'technic':16 'writer':17
741	ROMAN PUNK	A Thoughtful Panorama of a Mad Cow And a Student who must Battle a Forensic Psychologist in Berlin	2006	1	\N	7	0.99	81	28.99	NC-17	2006-02-15 05:03:42	{Trailers}	'battl':15 'berlin':20 'cow':9 'forens':17 'mad':8 'must':14 'panorama':5 'psychologist':18 'punk':2 'roman':1 'student':12 'thought':4
742	ROOF CHAMPION	A Lacklusture Reflection of a Car And a Explorer who must Find a Monkey in A Baloon	2006	1	\N	7	0.99	101	25.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'baloon':19 'car':8 'champion':2 'explor':11 'find':14 'lacklustur':4 'monkey':16 'must':13 'reflect':5 'roof':1
743	ROOM ROMAN	A Awe-Inspiring Panorama of a Composer And a Secret Agent who must Sink a Composer in A Shark Tank	2006	1	\N	7	0.99	60	27.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'agent':14 'awe':5 'awe-inspir':4 'compos':10,19 'inspir':6 'must':16 'panorama':7 'roman':2 'room':1 'secret':13 'shark':22 'sink':17 'tank':23
744	ROOTS REMEMBER	A Brilliant Drama of a Mad Cow And a Hunter who must Escape a Hunter in Berlin	2006	1	\N	4	0.99	89	23.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'berlin':19 'brilliant':4 'cow':9 'drama':5 'escap':15 'hunter':12,17 'mad':8 'must':14 'rememb':2 'root':1
745	ROSES TREASURE	A Astounding Panorama of a Monkey And a Secret Agent who must Defeat a Woman in The First Manned Space Station	2006	1	\N	5	4.99	162	23.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'agent':12 'astound':4 'defeat':15 'first':20 'man':21 'monkey':8 'must':14 'panorama':5 'rose':1 'secret':11 'space':22 'station':23 'treasur':2 'woman':17
746	ROUGE SQUAD	A Awe-Inspiring Drama of a Astronaut And a Frisbee who must Conquer a Mad Scientist in Australia	2006	1	\N	3	0.99	118	10.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'astronaut':10 'australia':21 'awe':5 'awe-inspir':4 'conquer':16 'drama':7 'frisbe':13 'inspir':6 'mad':18 'must':15 'roug':1 'scientist':19 'squad':2
747	ROXANNE REBEL	A Astounding Story of a Pastry Chef And a Database Administrator who must Fight a Man in The Outback	2006	1	\N	5	0.99	171	9.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'administr':13 'astound':4 'chef':9 'databas':12 'fight':16 'man':18 'must':15 'outback':21 'pastri':8 'rebel':2 'roxann':1 'stori':5
748	RUGRATS SHAKESPEARE	A Touching Saga of a Crocodile And a Crocodile who must Discover a Technical Writer in Nigeria	2006	1	\N	4	0.99	109	16.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'crocodil':8,11 'discov':14 'must':13 'nigeria':19 'rugrat':1 'saga':5 'shakespear':2 'technic':16 'touch':4 'writer':17
749	RULES HUMAN	A Beautiful Epistle of a Astronaut And a Student who must Confront a Monkey in An Abandoned Fun House	2006	1	\N	6	4.99	153	19.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'abandon':19 'astronaut':8 'beauti':4 'confront':14 'epistl':5 'fun':20 'hous':21 'human':2 'monkey':16 'must':13 'rule':1 'student':11
750	RUN PACIFIC	A Touching Tale of a Cat And a Pastry Chef who must Conquer a Pastry Chef in A MySQL Convention	2006	1	\N	3	0.99	145	25.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'cat':8 'chef':12,18 'conquer':15 'convent':22 'must':14 'mysql':21 'pacif':2 'pastri':11,17 'run':1 'tale':5 'touch':4
751	RUNAWAY TENENBAUMS	A Thoughtful Documentary of a Boat And a Man who must Meet a Boat in An Abandoned Fun House	2006	1	\N	6	0.99	181	17.99	NC-17	2006-02-15 05:03:42	{Commentaries}	'abandon':19 'boat':8,16 'documentari':5 'fun':20 'hous':21 'man':11 'meet':14 'must':13 'runaway':1 'tenenbaum':2 'thought':4
752	RUNNER MADIGAN	A Thoughtful Documentary of a Crocodile And a Robot who must Outrace a Womanizer in The Outback	2006	1	\N	6	0.99	101	27.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'crocodil':8 'documentari':5 'madigan':2 'must':13 'outback':19 'outrac':14 'robot':11 'runner':1 'thought':4 'woman':16
754	RUSHMORE MERMAID	A Boring Story of a Woman And a Moose who must Reach a Husband in A Shark Tank	2006	1	\N	6	2.99	150	17.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'bore':4 'husband':16 'mermaid':2 'moos':11 'must':13 'reach':14 'rushmor':1 'shark':19 'stori':5 'tank':20 'woman':8
755	SABRINA MIDNIGHT	A Emotional Story of a Squirrel And a Crocodile who must Succumb a Husband in The Sahara Desert	2006	1	\N	5	4.99	99	11.99	PG	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'crocodil':11 'desert':20 'emot':4 'husband':16 'midnight':2 'must':13 'sabrina':1 'sahara':19 'squirrel':8 'stori':5 'succumb':14
756	SADDLE ANTITRUST	A Stunning Epistle of a Feminist And a A Shark who must Battle a Woman in An Abandoned Fun House	2006	1	\N	7	2.99	80	10.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'abandon':20 'antitrust':2 'battl':15 'epistl':5 'feminist':8 'fun':21 'hous':22 'must':14 'saddl':1 'shark':12 'stun':4 'woman':17
757	SAGEBRUSH CLUELESS	A Insightful Story of a Lumberjack And a Hunter who must Kill a Boy in Ancient Japan	2006	1	\N	4	2.99	106	28.99	G	2006-02-15 05:03:42	{Trailers}	'ancient':18 'boy':16 'clueless':2 'hunter':11 'insight':4 'japan':19 'kill':14 'lumberjack':8 'must':13 'sagebrush':1 'stori':5
758	SAINTS BRIDE	A Fateful Tale of a Technical Writer And a Composer who must Pursue a Explorer in The Gulf of Mexico	2006	1	\N	5	2.99	125	11.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'bride':2 'compos':12 'explor':17 'fate':4 'gulf':20 'mexico':22 'must':14 'pursu':15 'saint':1 'tale':5 'technic':8 'writer':9
759	SALUTE APOLLO	A Awe-Inspiring Character Study of a Boy And a Feminist who must Sink a Crocodile in Ancient China	2006	1	\N	4	2.99	73	29.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'ancient':21 'apollo':2 'awe':5 'awe-inspir':4 'boy':11 'charact':7 'china':22 'crocodil':19 'feminist':14 'inspir':6 'must':16 'salut':1 'sink':17 'studi':8
760	SAMURAI LION	A Fast-Paced Story of a Pioneer And a Astronaut who must Reach a Boat in A Baloon	2006	1	\N	5	2.99	110	21.99	G	2006-02-15 05:03:42	{Commentaries}	'astronaut':13 'baloon':21 'boat':18 'fast':5 'fast-pac':4 'lion':2 'must':15 'pace':6 'pioneer':10 'reach':16 'samurai':1 'stori':7
761	SANTA PARIS	A Emotional Documentary of a Moose And a Car who must Redeem a Mad Cow in A Baloon Factory	2006	1	\N	7	2.99	154	23.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'baloon':20 'car':11 'cow':17 'documentari':5 'emot':4 'factori':21 'mad':16 'moos':8 'must':13 'pari':2 'redeem':14 'santa':1
762	SASSY PACKER	A Fast-Paced Documentary of a Dog And a Teacher who must Find a Moose in A Manhattan Penthouse	2006	1	\N	6	0.99	154	29.99	G	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'documentari':7 'dog':10 'fast':5 'fast-pac':4 'find':16 'manhattan':21 'moos':18 'must':15 'pace':6 'packer':2 'penthous':22 'sassi':1 'teacher':13
763	SATISFACTION CONFIDENTIAL	A Lacklusture Yarn of a Dentist And a Butler who must Meet a Secret Agent in Ancient China	2006	1	\N	3	4.99	75	26.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'agent':17 'ancient':19 'butler':11 'china':20 'confidenti':2 'dentist':8 'lacklustur':4 'meet':14 'must':13 'satisfact':1 'secret':16 'yarn':5
764	SATURDAY LAMBS	A Thoughtful Reflection of a Mad Scientist And a Moose who must Kill a Husband in A Baloon	2006	1	\N	3	4.99	150	28.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'baloon':20 'husband':17 'kill':15 'lamb':2 'mad':8 'moos':12 'must':14 'reflect':5 'saturday':1 'scientist':9 'thought':4
765	SATURN NAME	A Fateful Epistle of a Butler And a Boy who must Redeem a Teacher in Berlin	2006	1	\N	7	4.99	182	18.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'berlin':18 'boy':11 'butler':8 'epistl':5 'fate':4 'must':13 'name':2 'redeem':14 'saturn':1 'teacher':16
766	SAVANNAH TOWN	A Awe-Inspiring Tale of a Astronaut And a Database Administrator who must Chase a Secret Agent in The Gulf of Mexico	2006	1	\N	5	0.99	84	25.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'administr':14 'agent':20 'astronaut':10 'awe':5 'awe-inspir':4 'chase':17 'databas':13 'gulf':23 'inspir':6 'mexico':25 'must':16 'savannah':1 'secret':19 'tale':7 'town':2
767	SCALAWAG DUCK	A Fateful Reflection of a Car And a Teacher who must Confront a Waitress in A Monastery	2006	1	\N	6	4.99	183	13.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'car':8 'confront':14 'duck':2 'fate':4 'monasteri':19 'must':13 'reflect':5 'scalawag':1 'teacher':11 'waitress':16
768	SCARFACE BANG	A Emotional Yarn of a Teacher And a Girl who must Find a Teacher in A Baloon Factory	2006	1	\N	3	4.99	102	11.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'baloon':19 'bang':2 'emot':4 'factori':20 'find':14 'girl':11 'must':13 'scarfac':1 'teacher':8,16 'yarn':5
769	SCHOOL JACKET	A Intrepid Yarn of a Monkey And a Boy who must Fight a Composer in A Manhattan Penthouse	2006	1	\N	5	4.99	151	21.99	PG-13	2006-02-15 05:03:42	{Trailers}	'boy':11 'compos':16 'fight':14 'intrepid':4 'jacket':2 'manhattan':19 'monkey':8 'must':13 'penthous':20 'school':1 'yarn':5
770	SCISSORHANDS SLUMS	A Awe-Inspiring Drama of a Girl And a Technical Writer who must Meet a Feminist in The Canadian Rockies	2006	1	\N	5	2.99	147	13.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'awe':5 'awe-inspir':4 'canadian':22 'drama':7 'feminist':19 'girl':10 'inspir':6 'meet':17 'must':16 'rocki':23 'scissorhand':1 'slum':2 'technic':13 'writer':14
771	SCORPION APOLLO	A Awe-Inspiring Documentary of a Technical Writer And a Husband who must Meet a Monkey in An Abandoned Fun House	2006	1	\N	3	4.99	137	23.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'abandon':22 'apollo':2 'awe':5 'awe-inspir':4 'documentari':7 'fun':23 'hous':24 'husband':14 'inspir':6 'meet':17 'monkey':19 'must':16 'scorpion':1 'technic':10 'writer':11
772	SEA VIRGIN	A Fast-Paced Documentary of a Technical Writer And a Pastry Chef who must Escape a Moose in A U-Boat	2006	1	\N	4	2.99	80	24.99	PG	2006-02-15 05:03:42	{"Deleted Scenes"}	'boat':25 'chef':15 'documentari':7 'escap':18 'fast':5 'fast-pac':4 'moos':20 'must':17 'pace':6 'pastri':14 'sea':1 'technic':10 'u':24 'u-boat':23 'virgin':2 'writer':11
773	SEABISCUIT PUNK	A Insightful Saga of a Man And a Forensic Psychologist who must Discover a Mad Cow in A MySQL Convention	2006	1	\N	6	2.99	112	28.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'convent':22 'cow':18 'discov':15 'forens':11 'insight':4 'mad':17 'man':8 'must':14 'mysql':21 'psychologist':12 'punk':2 'saga':5 'seabiscuit':1
774	SEARCHERS WAIT	A Fast-Paced Tale of a Car And a Mad Scientist who must Kill a Womanizer in Ancient Japan	2006	1	\N	3	2.99	182	22.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'ancient':21 'car':10 'fast':5 'fast-pac':4 'japan':22 'kill':17 'mad':13 'must':16 'pace':6 'scientist':14 'searcher':1 'tale':7 'wait':2 'woman':19
775	SEATTLE EXPECATIONS	A Insightful Reflection of a Crocodile And a Sumo Wrestler who must Meet a Technical Writer in The Sahara Desert	2006	1	\N	4	4.99	110	18.99	PG-13	2006-02-15 05:03:42	{Trailers}	'crocodil':8 'desert':22 'expec':2 'insight':4 'meet':15 'must':14 'reflect':5 'sahara':21 'seattl':1 'sumo':11 'technic':17 'wrestler':12 'writer':18
776	SECRET GROUNDHOG	A Astounding Story of a Cat And a Database Administrator who must Build a Technical Writer in New Orleans	2006	1	\N	6	4.99	90	11.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'administr':12 'astound':4 'build':15 'cat':8 'databas':11 'groundhog':2 'must':14 'new':20 'orlean':21 'secret':1 'stori':5 'technic':17 'writer':18
777	SECRETARY ROUGE	A Action-Packed Panorama of a Mad Cow And a Composer who must Discover a Robot in A Baloon Factory	2006	1	\N	5	4.99	158	10.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'action':5 'action-pack':4 'baloon':22 'compos':14 'cow':11 'discov':17 'factori':23 'mad':10 'must':16 'pack':6 'panorama':7 'robot':19 'roug':2 'secretari':1
778	SECRETS PARADISE	A Fateful Saga of a Cat And a Frisbee who must Kill a Girl in A Manhattan Penthouse	2006	1	\N	3	4.99	109	24.99	G	2006-02-15 05:03:42	{Trailers,Commentaries}	'cat':8 'fate':4 'frisbe':11 'girl':16 'kill':14 'manhattan':19 'must':13 'paradis':2 'penthous':20 'saga':5 'secret':1
779	SENSE GREEK	A Taut Saga of a Lumberjack And a Pastry Chef who must Escape a Sumo Wrestler in An Abandoned Fun House	2006	1	\N	4	4.99	54	23.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'abandon':21 'chef':12 'escap':15 'fun':22 'greek':2 'hous':23 'lumberjack':8 'must':14 'pastri':11 'saga':5 'sens':1 'sumo':17 'taut':4 'wrestler':18
780	SENSIBILITY REAR	A Emotional Tale of a Robot And a Sumo Wrestler who must Redeem a Pastry Chef in A Baloon Factory	2006	1	\N	7	4.99	98	15.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'baloon':21 'chef':18 'emot':4 'factori':22 'must':14 'pastri':17 'rear':2 'redeem':15 'robot':8 'sensibl':1 'sumo':11 'tale':5 'wrestler':12
781	SEVEN SWARM	A Unbelieveable Character Study of a Dog And a Mad Cow who must Kill a Monkey in Berlin	2006	1	\N	4	4.99	127	15.99	R	2006-02-15 05:03:42	{"Deleted Scenes"}	'berlin':20 'charact':5 'cow':13 'dog':9 'kill':16 'mad':12 'monkey':18 'must':15 'seven':1 'studi':6 'swarm':2 'unbeliev':4
782	SHAKESPEARE SADDLE	A Fast-Paced Panorama of a Lumberjack And a Database Administrator who must Defeat a Madman in A MySQL Convention	2006	1	\N	6	2.99	60	26.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'administr':14 'convent':23 'databas':13 'defeat':17 'fast':5 'fast-pac':4 'lumberjack':10 'madman':19 'must':16 'mysql':22 'pace':6 'panorama':7 'saddl':2 'shakespear':1
783	SHANE DARKNESS	A Action-Packed Saga of a Moose And a Lumberjack who must Find a Woman in Berlin	2006	1	\N	5	2.99	93	22.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'action':5 'action-pack':4 'berlin':20 'dark':2 'find':16 'lumberjack':13 'moos':10 'must':15 'pack':6 'saga':7 'shane':1 'woman':18
784	SHANGHAI TYCOON	A Fast-Paced Character Study of a Crocodile And a Lumberjack who must Build a Husband in An Abandoned Fun House	2006	1	\N	7	2.99	47	20.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':22 'build':17 'charact':7 'crocodil':11 'fast':5 'fast-pac':4 'fun':23 'hous':24 'husband':19 'lumberjack':14 'must':16 'pace':6 'shanghai':1 'studi':8 'tycoon':2
785	SHAWSHANK BUBBLE	A Lacklusture Story of a Moose And a Monkey who must Confront a Butler in An Abandoned Amusement Park	2006	1	\N	6	4.99	80	20.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'abandon':19 'amus':20 'bubbl':2 'butler':16 'confront':14 'lacklustur':4 'monkey':11 'moos':8 'must':13 'park':21 'shawshank':1 'stori':5
786	SHEPHERD MIDSUMMER	A Thoughtful Drama of a Robot And a Womanizer who must Kill a Lumberjack in A Baloon	2006	1	\N	7	0.99	113	14.99	R	2006-02-15 05:03:42	{"Deleted Scenes"}	'baloon':19 'drama':5 'kill':14 'lumberjack':16 'midsumm':2 'must':13 'robot':8 'shepherd':1 'thought':4 'woman':11
787	SHINING ROSES	A Awe-Inspiring Character Study of a Astronaut And a Forensic Psychologist who must Challenge a Madman in Ancient India	2006	1	\N	4	0.99	125	12.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'ancient':22 'astronaut':11 'awe':5 'awe-inspir':4 'challeng':18 'charact':7 'forens':14 'india':23 'inspir':6 'madman':20 'must':17 'psychologist':15 'rose':2 'shine':1 'studi':8
788	SHIP WONDERLAND	A Thrilling Saga of a Monkey And a Frisbee who must Escape a Explorer in The Outback	2006	1	\N	5	2.99	104	15.99	R	2006-02-15 05:03:42	{Commentaries}	'escap':14 'explor':16 'frisbe':11 'monkey':8 'must':13 'outback':19 'saga':5 'ship':1 'thrill':4 'wonderland':2
789	SHOCK CABIN	A Fateful Tale of a Mad Cow And a Crocodile who must Meet a Husband in New Orleans	2006	1	\N	7	2.99	79	15.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'cabin':2 'cow':9 'crocodil':12 'fate':4 'husband':17 'mad':8 'meet':15 'must':14 'new':19 'orlean':20 'shock':1 'tale':5
790	SHOOTIST SUPERFLY	A Fast-Paced Story of a Crocodile And a A Shark who must Sink a Pioneer in Berlin	2006	1	\N	6	0.99	67	22.99	PG-13	2006-02-15 05:03:42	{Trailers}	'berlin':21 'crocodil':10 'fast':5 'fast-pac':4 'must':16 'pace':6 'pioneer':19 'shark':14 'shootist':1 'sink':17 'stori':7 'superfli':2
791	SHOW LORD	A Fanciful Saga of a Student And a Girl who must Find a Butler in Ancient Japan	2006	1	\N	3	4.99	167	24.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'ancient':18 'butler':16 'fanci':4 'find':14 'girl':11 'japan':19 'lord':2 'must':13 'saga':5 'show':1 'student':8
792	SHREK LICENSE	A Fateful Yarn of a Secret Agent And a Feminist who must Find a Feminist in A Jet Boat	2006	1	\N	7	2.99	154	15.99	PG-13	2006-02-15 05:03:42	{Commentaries}	'agent':9 'boat':21 'fate':4 'feminist':12,17 'find':15 'jet':20 'licens':2 'must':14 'secret':8 'shrek':1 'yarn':5
793	SHRUNK DIVINE	A Fateful Character Study of a Waitress And a Technical Writer who must Battle a Hunter in A Baloon	2006	1	\N	6	2.99	139	14.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'baloon':21 'battl':16 'charact':5 'divin':2 'fate':4 'hunter':18 'must':15 'shrunk':1 'studi':6 'technic':12 'waitress':9 'writer':13
794	SIDE ARK	A Stunning Panorama of a Crocodile And a Womanizer who must Meet a Feminist in The Canadian Rockies	2006	1	\N	5	0.99	52	28.99	G	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'ark':2 'canadian':19 'crocodil':8 'feminist':16 'meet':14 'must':13 'panorama':5 'rocki':20 'side':1 'stun':4 'woman':11
795	SIEGE MADRE	A Boring Tale of a Frisbee And a Crocodile who must Vanquish a Moose in An Abandoned Mine Shaft	2006	1	\N	7	0.99	111	23.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'abandon':19 'bore':4 'crocodil':11 'frisbe':8 'madr':2 'mine':20 'moos':16 'must':13 'shaft':21 'sieg':1 'tale':5 'vanquish':14
796	SIERRA DIVIDE	A Emotional Character Study of a Frisbee And a Mad Scientist who must Build a Madman in California	2006	1	\N	3	0.99	135	12.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'build':16 'california':20 'charact':5 'divid':2 'emot':4 'frisbe':9 'mad':12 'madman':18 'must':15 'scientist':13 'sierra':1 'studi':6
797	SILENCE KANE	A Emotional Drama of a Sumo Wrestler And a Dentist who must Confront a Sumo Wrestler in A Baloon	2006	1	\N	7	0.99	67	23.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'baloon':21 'confront':15 'dentist':12 'drama':5 'emot':4 'kane':2 'must':14 'silenc':1 'sumo':8,17 'wrestler':9,18
798	SILVERADO GOLDFINGER	A Stunning Epistle of a Sumo Wrestler And a Man who must Challenge a Waitress in Ancient India	2006	1	\N	4	4.99	74	11.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'ancient':19 'challeng':15 'epistl':5 'goldfing':2 'india':20 'man':12 'must':14 'silverado':1 'stun':4 'sumo':8 'waitress':17 'wrestler':9
799	SIMON NORTH	A Thrilling Documentary of a Technical Writer And a A Shark who must Face a Pioneer in A Shark Tank	2006	1	\N	3	0.99	51	26.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries}	'documentari':5 'face':16 'must':15 'north':2 'pioneer':18 'shark':13,21 'simon':1 'tank':22 'technic':8 'thrill':4 'writer':9
800	SINNERS ATLANTIS	A Epic Display of a Dog And a Boat who must Succumb a Mad Scientist in An Abandoned Mine Shaft	2006	1	\N	7	2.99	126	19.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'abandon':20 'atlanti':2 'boat':11 'display':5 'dog':8 'epic':4 'mad':16 'mine':21 'must':13 'scientist':17 'shaft':22 'sinner':1 'succumb':14
801	SISTER FREDDY	A Stunning Saga of a Butler And a Woman who must Pursue a Explorer in Australia	2006	1	\N	5	4.99	152	19.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'australia':18 'butler':8 'explor':16 'freddi':2 'must':13 'pursu':14 'saga':5 'sister':1 'stun':4 'woman':11
802	SKY MIRACLE	A Epic Drama of a Mad Scientist And a Explorer who must Succumb a Waitress in An Abandoned Fun House	2006	1	\N	7	2.99	132	15.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'abandon':20 'drama':5 'epic':4 'explor':12 'fun':21 'hous':22 'mad':8 'miracl':2 'must':14 'scientist':9 'sky':1 'succumb':15 'waitress':17
803	SLACKER LIAISONS	A Fast-Paced Tale of a A Shark And a Student who must Meet a Crocodile in Ancient China	2006	1	\N	7	4.99	179	29.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'ancient':21 'china':22 'crocodil':19 'fast':5 'fast-pac':4 'liaison':2 'meet':17 'must':16 'pace':6 'shark':11 'slacker':1 'student':14 'tale':7
804	SLEEPING SUSPECTS	A Stunning Reflection of a Sumo Wrestler And a Explorer who must Sink a Frisbee in A MySQL Convention	2006	1	\N	7	4.99	129	13.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'convent':21 'explor':12 'frisbe':17 'must':14 'mysql':20 'reflect':5 'sink':15 'sleep':1 'stun':4 'sumo':8 'suspect':2 'wrestler':9
805	SLEEPLESS MONSOON	A Amazing Saga of a Moose And a Pastry Chef who must Escape a Butler in Australia	2006	1	\N	5	4.99	64	12.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'amaz':4 'australia':19 'butler':17 'chef':12 'escap':15 'monsoon':2 'moos':8 'must':14 'pastri':11 'saga':5 'sleepless':1
806	SLEEPY JAPANESE	A Emotional Epistle of a Moose And a Composer who must Fight a Technical Writer in The Outback	2006	1	\N	4	2.99	137	25.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'compos':11 'emot':4 'epistl':5 'fight':14 'japanes':2 'moos':8 'must':13 'outback':20 'sleepi':1 'technic':16 'writer':17
807	SLEUTH ORIENT	A Fateful Character Study of a Husband And a Dog who must Find a Feminist in Ancient India	2006	1	\N	4	0.99	87	25.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'ancient':19 'charact':5 'dog':12 'fate':4 'feminist':17 'find':15 'husband':9 'india':20 'must':14 'orient':2 'sleuth':1 'studi':6
808	SLING LUKE	A Intrepid Character Study of a Robot And a Monkey who must Reach a Secret Agent in An Abandoned Amusement Park	2006	1	\N	5	0.99	84	10.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'abandon':21 'agent':18 'amus':22 'charact':5 'intrepid':4 'luke':2 'monkey':12 'must':14 'park':23 'reach':15 'robot':9 'secret':17 'sling':1 'studi':6
809	SLIPPER FIDELITY	A Taut Reflection of a Secret Agent And a Man who must Redeem a Explorer in A MySQL Convention	2006	1	\N	5	0.99	156	14.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'agent':9 'convent':21 'explor':17 'fidel':2 'man':12 'must':14 'mysql':20 'redeem':15 'reflect':5 'secret':8 'slipper':1 'taut':4
810	SLUMS DUCK	A Amazing Character Study of a Teacher And a Database Administrator who must Defeat a Waitress in A Jet Boat	2006	1	\N	5	0.99	147	21.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'administr':13 'amaz':4 'boat':22 'charact':5 'databas':12 'defeat':16 'duck':2 'jet':21 'must':15 'slum':1 'studi':6 'teacher':9 'waitress':18
811	SMILE EARRING	A Intrepid Drama of a Teacher And a Butler who must Build a Pastry Chef in Berlin	2006	1	\N	4	2.99	60	29.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'berlin':19 'build':14 'butler':11 'chef':17 'drama':5 'earring':2 'intrepid':4 'must':13 'pastri':16 'smile':1 'teacher':8
812	SMOKING BARBARELLA	A Lacklusture Saga of a Mad Cow And a Mad Scientist who must Sink a Cat in A MySQL Convention	2006	1	\N	7	0.99	50	13.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'barbarella':2 'cat':18 'convent':22 'cow':9 'lacklustur':4 'mad':8,12 'must':15 'mysql':21 'saga':5 'scientist':13 'sink':16 'smoke':1
813	SMOOCHY CONTROL	A Thrilling Documentary of a Husband And a Feminist who must Face a Mad Scientist in Ancient China	2006	1	\N	7	0.99	184	18.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'ancient':19 'china':20 'control':2 'documentari':5 'face':14 'feminist':11 'husband':8 'mad':16 'must':13 'scientist':17 'smoochi':1 'thrill':4
814	SNATCH SLIPPER	A Insightful Panorama of a Woman And a Feminist who must Defeat a Forensic Psychologist in Berlin	2006	1	\N	6	4.99	110	15.99	PG	2006-02-15 05:03:42	{Commentaries}	'berlin':19 'defeat':14 'feminist':11 'forens':16 'insight':4 'must':13 'panorama':5 'psychologist':17 'slipper':2 'snatch':1 'woman':8
815	SNATCHERS MONTEZUMA	A Boring Epistle of a Sumo Wrestler And a Woman who must Escape a Man in The Canadian Rockies	2006	1	\N	4	2.99	74	14.99	PG-13	2006-02-15 05:03:42	{Commentaries}	'bore':4 'canadian':20 'epistl':5 'escap':15 'man':17 'montezuma':2 'must':14 'rocki':21 'snatcher':1 'sumo':8 'woman':12 'wrestler':9
816	SNOWMAN ROLLERCOASTER	A Fateful Display of a Lumberjack And a Girl who must Succumb a Mad Cow in A Manhattan Penthouse	2006	1	\N	3	0.99	62	27.99	G	2006-02-15 05:03:42	{Trailers}	'cow':17 'display':5 'fate':4 'girl':11 'lumberjack':8 'mad':16 'manhattan':20 'must':13 'penthous':21 'rollercoast':2 'snowman':1 'succumb':14
817	SOLDIERS EVOLUTION	A Lacklusture Panorama of a A Shark And a Pioneer who must Confront a Student in The First Manned Space Station	2006	1	\N	7	4.99	185	27.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'confront':15 'evolut':2 'first':20 'lacklustur':4 'man':21 'must':14 'panorama':5 'pioneer':12 'shark':9 'soldier':1 'space':22 'station':23 'student':17
818	SOMETHING DUCK	A Boring Character Study of a Car And a Husband who must Outgun a Frisbee in The First Manned Space Station	2006	1	\N	4	4.99	180	17.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'bore':4 'car':9 'charact':5 'duck':2 'first':20 'frisbe':17 'husband':12 'man':21 'must':14 'outgun':15 'someth':1 'space':22 'station':23 'studi':6
819	SONG HEDWIG	A Amazing Documentary of a Man And a Husband who must Confront a Squirrel in A MySQL Convention	2006	1	\N	3	0.99	165	29.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'amaz':4 'confront':14 'convent':20 'documentari':5 'hedwig':2 'husband':11 'man':8 'must':13 'mysql':19 'song':1 'squirrel':16
820	SONS INTERVIEW	A Taut Character Study of a Explorer And a Mad Cow who must Battle a Hunter in Ancient China	2006	1	\N	3	2.99	184	11.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'ancient':20 'battl':16 'charact':5 'china':21 'cow':13 'explor':9 'hunter':18 'interview':2 'mad':12 'must':15 'son':1 'studi':6 'taut':4
821	SORORITY QUEEN	A Fast-Paced Display of a Squirrel And a Composer who must Fight a Forensic Psychologist in A Jet Boat	2006	1	\N	6	0.99	184	17.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'boat':23 'compos':13 'display':7 'fast':5 'fast-pac':4 'fight':16 'forens':18 'jet':22 'must':15 'pace':6 'psychologist':19 'queen':2 'soror':1 'squirrel':10
822	SOUP WISDOM	A Fast-Paced Display of a Robot And a Butler who must Defeat a Butler in A MySQL Convention	2006	1	\N	6	0.99	169	12.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'butler':13,18 'convent':22 'defeat':16 'display':7 'fast':5 'fast-pac':4 'must':15 'mysql':21 'pace':6 'robot':10 'soup':1 'wisdom':2
823	SOUTH WAIT	A Amazing Documentary of a Car And a Robot who must Escape a Lumberjack in An Abandoned Amusement Park	2006	1	\N	4	2.99	143	21.99	R	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'abandon':19 'amaz':4 'amus':20 'car':8 'documentari':5 'escap':14 'lumberjack':16 'must':13 'park':21 'robot':11 'south':1 'wait':2
824	SPARTACUS CHEAPER	A Thrilling Panorama of a Pastry Chef And a Secret Agent who must Overcome a Student in A Manhattan Penthouse	2006	1	\N	4	4.99	52	19.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'agent':13 'cheaper':2 'chef':9 'manhattan':21 'must':15 'overcom':16 'panorama':5 'pastri':8 'penthous':22 'secret':12 'spartacus':1 'student':18 'thrill':4
825	SPEAKEASY DATE	A Lacklusture Drama of a Forensic Psychologist And a Car who must Redeem a Man in A Manhattan Penthouse	2006	1	\N	6	2.99	165	22.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'car':12 'date':2 'drama':5 'forens':8 'lacklustur':4 'man':17 'manhattan':20 'must':14 'penthous':21 'psychologist':9 'redeem':15 'speakeasi':1
826	SPEED SUIT	A Brilliant Display of a Frisbee And a Mad Scientist who must Succumb a Robot in Ancient China	2006	1	\N	7	4.99	124	19.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'ancient':19 'brilliant':4 'china':20 'display':5 'frisbe':8 'mad':11 'must':14 'robot':17 'scientist':12 'speed':1 'succumb':15 'suit':2
827	SPICE SORORITY	A Fateful Display of a Pioneer And a Hunter who must Defeat a Husband in An Abandoned Mine Shaft	2006	1	\N	5	4.99	141	22.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':19 'defeat':14 'display':5 'fate':4 'hunter':11 'husband':16 'mine':20 'must':13 'pioneer':8 'shaft':21 'soror':2 'spice':1
828	SPIKING ELEMENT	A Lacklusture Epistle of a Dentist And a Technical Writer who must Find a Dog in A Monastery	2006	1	\N	7	2.99	79	12.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'dentist':8 'dog':17 'element':2 'epistl':5 'find':15 'lacklustur':4 'monasteri':20 'must':14 'spike':1 'technic':11 'writer':12
829	SPINAL ROCKY	A Lacklusture Epistle of a Sumo Wrestler And a Squirrel who must Defeat a Explorer in California	2006	1	\N	7	2.99	138	12.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'california':19 'defeat':15 'epistl':5 'explor':17 'lacklustur':4 'must':14 'rocki':2 'spinal':1 'squirrel':12 'sumo':8 'wrestler':9
830	SPIRIT FLINTSTONES	A Brilliant Yarn of a Cat And a Car who must Confront a Explorer in Ancient Japan	2006	1	\N	7	0.99	149	23.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'ancient':18 'brilliant':4 'car':11 'cat':8 'confront':14 'explor':16 'flintston':2 'japan':19 'must':13 'spirit':1 'yarn':5
831	SPIRITED CASUALTIES	A Taut Story of a Waitress And a Man who must Face a Car in A Baloon Factory	2006	1	\N	5	0.99	138	20.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'baloon':19 'car':16 'casualti':2 'face':14 'factori':20 'man':11 'must':13 'spirit':1 'stori':5 'taut':4 'waitress':8
832	SPLASH GUMP	A Taut Saga of a Crocodile And a Boat who must Conquer a Hunter in A Shark Tank	2006	1	\N	5	0.99	175	16.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'boat':11 'conquer':14 'crocodil':8 'gump':2 'hunter':16 'must':13 'saga':5 'shark':19 'splash':1 'tank':20 'taut':4
833	SPLENDOR PATTON	A Taut Story of a Dog And a Explorer who must Find a Astronaut in Berlin	2006	1	\N	5	0.99	134	20.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'astronaut':16 'berlin':18 'dog':8 'explor':11 'find':14 'must':13 'patton':2 'splendor':1 'stori':5 'taut':4
834	SPOILERS HELLFIGHTERS	A Fanciful Story of a Technical Writer And a Squirrel who must Defeat a Dog in The Gulf of Mexico	2006	1	\N	4	0.99	151	26.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'defeat':15 'dog':17 'fanci':4 'gulf':20 'hellfight':2 'mexico':22 'must':14 'spoiler':1 'squirrel':12 'stori':5 'technic':8 'writer':9
835	SPY MILE	A Thrilling Documentary of a Feminist And a Feminist who must Confront a Feminist in A Baloon	2006	1	\N	6	2.99	112	13.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'baloon':19 'confront':14 'documentari':5 'feminist':8,11,16 'mile':2 'must':13 'spi':1 'thrill':4
836	SQUAD FISH	A Fast-Paced Display of a Pastry Chef And a Dog who must Kill a Teacher in Berlin	2006	1	\N	3	2.99	136	14.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'berlin':21 'chef':11 'display':7 'dog':14 'fast':5 'fast-pac':4 'fish':2 'kill':17 'must':16 'pace':6 'pastri':10 'squad':1 'teacher':19
837	STAGE WORLD	A Lacklusture Panorama of a Woman And a Frisbee who must Chase a Crocodile in A Jet Boat	2006	1	\N	4	2.99	85	19.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'boat':20 'chase':14 'crocodil':16 'frisbe':11 'jet':19 'lacklustur':4 'must':13 'panorama':5 'stage':1 'woman':8 'world':2
838	STAGECOACH ARMAGEDDON	A Touching Display of a Pioneer And a Butler who must Chase a Car in California	2006	1	\N	5	4.99	112	25.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'armageddon':2 'butler':11 'california':18 'car':16 'chase':14 'display':5 'must':13 'pioneer':8 'stagecoach':1 'touch':4
839	STALLION SUNDANCE	A Fast-Paced Tale of a Car And a Dog who must Outgun a A Shark in Australia	2006	1	\N	5	0.99	130	23.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'australia':21 'car':10 'dog':13 'fast':5 'fast-pac':4 'must':15 'outgun':16 'pace':6 'shark':19 'stallion':1 'sundanc':2 'tale':7
840	STAMPEDE DISTURBING	A Unbelieveable Tale of a Woman And a Lumberjack who must Fight a Frisbee in A U-Boat	2006	1	\N	5	0.99	75	26.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'boat':21 'disturb':2 'fight':14 'frisbe':16 'lumberjack':11 'must':13 'stamped':1 'tale':5 'u':20 'u-boat':19 'unbeliev':4 'woman':8
841	STAR OPERATION	A Insightful Character Study of a Girl And a Car who must Pursue a Mad Cow in A Shark Tank	2006	1	\N	5	2.99	181	9.99	PG	2006-02-15 05:03:42	{Commentaries}	'car':12 'charact':5 'cow':18 'girl':9 'insight':4 'mad':17 'must':14 'oper':2 'pursu':15 'shark':21 'star':1 'studi':6 'tank':22
842	STATE WASTELAND	A Beautiful Display of a Cat And a Pastry Chef who must Outrace a Mad Cow in A Jet Boat	2006	1	\N	4	2.99	113	13.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'beauti':4 'boat':22 'cat':8 'chef':12 'cow':18 'display':5 'jet':21 'mad':17 'must':14 'outrac':15 'pastri':11 'state':1 'wasteland':2
843	STEEL SANTA	A Fast-Paced Yarn of a Composer And a Frisbee who must Face a Moose in Nigeria	2006	1	\N	4	4.99	143	15.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'compos':10 'face':16 'fast':5 'fast-pac':4 'frisbe':13 'moos':18 'must':15 'nigeria':20 'pace':6 'santa':2 'steel':1 'yarn':7
844	STEERS ARMAGEDDON	A Stunning Character Study of a Car And a Girl who must Succumb a Car in A MySQL Convention	2006	1	\N	6	4.99	140	16.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'armageddon':2 'car':9,17 'charact':5 'convent':21 'girl':12 'must':14 'mysql':20 'steer':1 'studi':6 'stun':4 'succumb':15
845	STEPMOM DREAM	A Touching Epistle of a Crocodile And a Teacher who must Build a Forensic Psychologist in A MySQL Convention	2006	1	\N	7	4.99	48	9.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'build':14 'convent':21 'crocodil':8 'dream':2 'epistl':5 'forens':16 'must':13 'mysql':20 'psychologist':17 'stepmom':1 'teacher':11 'touch':4
846	STING PERSONAL	A Fanciful Drama of a Frisbee And a Dog who must Fight a Madman in A Jet Boat	2006	1	\N	3	4.99	93	9.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'boat':20 'dog':11 'drama':5 'fanci':4 'fight':14 'frisbe':8 'jet':19 'madman':16 'must':13 'person':2 'sting':1
847	STOCK GLASS	A Boring Epistle of a Crocodile And a Lumberjack who must Outgun a Moose in Ancient China	2006	1	\N	7	2.99	160	10.99	PG	2006-02-15 05:03:42	{Commentaries}	'ancient':18 'bore':4 'china':19 'crocodil':8 'epistl':5 'glass':2 'lumberjack':11 'moos':16 'must':13 'outgun':14 'stock':1
848	STONE FIRE	A Intrepid Drama of a Astronaut And a Crocodile who must Find a Boat in Soviet Georgia	2006	1	\N	3	0.99	94	19.99	G	2006-02-15 05:03:42	{Trailers}	'astronaut':8 'boat':16 'crocodil':11 'drama':5 'find':14 'fire':2 'georgia':19 'intrepid':4 'must':13 'soviet':18 'stone':1
849	STORM HAPPINESS	A Insightful Drama of a Feminist And a A Shark who must Vanquish a Boat in A Shark Tank	2006	1	\N	6	0.99	57	28.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'boat':17 'drama':5 'feminist':8 'happi':2 'insight':4 'must':14 'shark':12,20 'storm':1 'tank':21 'vanquish':15
850	STORY SIDE	A Lacklusture Saga of a Boy And a Cat who must Sink a Dentist in An Abandoned Mine Shaft	2006	1	\N	7	0.99	163	27.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'abandon':19 'boy':8 'cat':11 'dentist':16 'lacklustur':4 'mine':20 'must':13 'saga':5 'shaft':21 'side':2 'sink':14 'stori':1
851	STRAIGHT HOURS	A Boring Panorama of a Secret Agent And a Girl who must Sink a Waitress in The Outback	2006	1	\N	3	0.99	151	19.99	R	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'agent':9 'bore':4 'girl':12 'hour':2 'must':14 'outback':20 'panorama':5 'secret':8 'sink':15 'straight':1 'waitress':17
852	STRANGELOVE DESIRE	A Awe-Inspiring Panorama of a Lumberjack And a Waitress who must Defeat a Crocodile in An Abandoned Amusement Park	2006	1	\N	4	0.99	103	27.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'abandon':21 'amus':22 'awe':5 'awe-inspir':4 'crocodil':18 'defeat':16 'desir':2 'inspir':6 'lumberjack':10 'must':15 'panorama':7 'park':23 'strangelov':1 'waitress':13
853	STRANGER STRANGERS	A Awe-Inspiring Yarn of a Womanizer And a Explorer who must Fight a Woman in The First Manned Space Station	2006	1	\N	3	4.99	139	12.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'awe':5 'awe-inspir':4 'explor':13 'fight':16 'first':21 'inspir':6 'man':22 'must':15 'space':23 'station':24 'stranger':1,2 'woman':10,18 'yarn':7
854	STRANGERS GRAFFITI	A Brilliant Character Study of a Secret Agent And a Man who must Find a Cat in The Gulf of Mexico	2006	1	\N	4	4.99	119	22.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'agent':10 'brilliant':4 'cat':18 'charact':5 'find':16 'graffiti':2 'gulf':21 'man':13 'mexico':23 'must':15 'secret':9 'stranger':1 'studi':6
855	STREAK RIDGEMONT	A Astounding Character Study of a Hunter And a Waitress who must Sink a Man in New Orleans	2006	1	\N	7	0.99	132	28.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'astound':4 'charact':5 'hunter':9 'man':17 'must':14 'new':19 'orlean':20 'ridgemont':2 'sink':15 'streak':1 'studi':6 'waitress':12
856	STREETCAR INTENTIONS	A Insightful Character Study of a Waitress And a Crocodile who must Sink a Waitress in The Gulf of Mexico	2006	1	\N	5	4.99	73	11.99	R	2006-02-15 05:03:42	{Commentaries}	'charact':5 'crocodil':12 'gulf':20 'insight':4 'intent':2 'mexico':22 'must':14 'sink':15 'streetcar':1 'studi':6 'waitress':9,17
857	STRICTLY SCARFACE	A Touching Reflection of a Crocodile And a Dog who must Chase a Hunter in An Abandoned Fun House	2006	1	\N	3	2.99	144	24.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'abandon':19 'chase':14 'crocodil':8 'dog':11 'fun':20 'hous':21 'hunter':16 'must':13 'reflect':5 'scarfac':2 'strict':1 'touch':4
858	SUBMARINE BED	A Amazing Display of a Car And a Monkey who must Fight a Teacher in Soviet Georgia	2006	1	\N	5	4.99	127	21.99	R	2006-02-15 05:03:42	{Trailers}	'amaz':4 'bed':2 'car':8 'display':5 'fight':14 'georgia':19 'monkey':11 'must':13 'soviet':18 'submarin':1 'teacher':16
859	SUGAR WONKA	A Touching Story of a Dentist And a Database Administrator who must Conquer a Astronaut in An Abandoned Amusement Park	2006	1	\N	3	4.99	114	20.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'abandon':20 'administr':12 'amus':21 'astronaut':17 'conquer':15 'databas':11 'dentist':8 'must':14 'park':22 'stori':5 'sugar':1 'touch':4 'wonka':2
860	SUICIDES SILENCE	A Emotional Character Study of a Car And a Girl who must Face a Composer in A U-Boat	2006	1	\N	4	4.99	93	13.99	G	2006-02-15 05:03:42	{"Deleted Scenes"}	'boat':22 'car':9 'charact':5 'compos':17 'emot':4 'face':15 'girl':12 'must':14 'silenc':2 'studi':6 'suicid':1 'u':21 'u-boat':20
861	SUIT WALLS	A Touching Panorama of a Lumberjack And a Frisbee who must Build a Dog in Australia	2006	1	\N	3	4.99	111	12.99	R	2006-02-15 05:03:42	{Commentaries}	'australia':18 'build':14 'dog':16 'frisbe':11 'lumberjack':8 'must':13 'panorama':5 'suit':1 'touch':4 'wall':2
862	SUMMER SCARFACE	A Emotional Panorama of a Lumberjack And a Hunter who must Meet a Girl in A Shark Tank	2006	1	\N	5	0.99	53	25.99	G	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'emot':4 'girl':16 'hunter':11 'lumberjack':8 'meet':14 'must':13 'panorama':5 'scarfac':2 'shark':19 'summer':1 'tank':20
863	SUN CONFESSIONS	A Beautiful Display of a Mad Cow And a Dog who must Redeem a Waitress in An Abandoned Amusement Park	2006	1	\N	5	0.99	141	9.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'abandon':20 'amus':21 'beauti':4 'confess':2 'cow':9 'display':5 'dog':12 'mad':8 'must':14 'park':22 'redeem':15 'sun':1 'waitress':17
864	SUNDANCE INVASION	A Epic Drama of a Lumberjack And a Explorer who must Confront a Hunter in A Baloon Factory	2006	1	\N	5	0.99	92	21.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'baloon':19 'confront':14 'drama':5 'epic':4 'explor':11 'factori':20 'hunter':16 'invas':2 'lumberjack':8 'must':13 'sundanc':1
865	SUNRISE LEAGUE	A Beautiful Epistle of a Madman And a Butler who must Face a Crocodile in A Manhattan Penthouse	2006	1	\N	3	4.99	135	19.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'beauti':4 'butler':11 'crocodil':16 'epistl':5 'face':14 'leagu':2 'madman':8 'manhattan':19 'must':13 'penthous':20 'sunris':1
866	SUNSET RACER	A Awe-Inspiring Reflection of a Astronaut And a A Shark who must Defeat a Forensic Psychologist in California	2006	1	\N	6	0.99	48	28.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'astronaut':10 'awe':5 'awe-inspir':4 'california':22 'defeat':17 'forens':19 'inspir':6 'must':16 'psychologist':20 'racer':2 'reflect':7 'shark':14 'sunset':1
867	SUPER WYOMING	A Action-Packed Saga of a Pastry Chef And a Explorer who must Discover a A Shark in The Outback	2006	1	\N	5	4.99	58	10.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'action':5 'action-pack':4 'chef':11 'discov':17 'explor':14 'must':16 'outback':23 'pack':6 'pastri':10 'saga':7 'shark':20 'super':1 'wyom':2
868	SUPERFLY TRIP	A Beautiful Saga of a Lumberjack And a Teacher who must Build a Technical Writer in An Abandoned Fun House	2006	1	\N	5	0.99	114	27.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'abandon':20 'beauti':4 'build':14 'fun':21 'hous':22 'lumberjack':8 'must':13 'saga':5 'superfli':1 'teacher':11 'technic':16 'trip':2 'writer':17
869	SUSPECTS QUILLS	A Emotional Epistle of a Pioneer And a Crocodile who must Battle a Man in A Manhattan Penthouse	2006	1	\N	4	2.99	47	22.99	PG	2006-02-15 05:03:42	{Trailers}	'battl':14 'crocodil':11 'emot':4 'epistl':5 'man':16 'manhattan':19 'must':13 'penthous':20 'pioneer':8 'quill':2 'suspect':1
870	SWARM GOLD	A Insightful Panorama of a Crocodile And a Boat who must Conquer a Sumo Wrestler in A MySQL Convention	2006	1	\N	4	0.99	123	12.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'boat':11 'conquer':14 'convent':21 'crocodil':8 'gold':2 'insight':4 'must':13 'mysql':20 'panorama':5 'sumo':16 'swarm':1 'wrestler':17
871	SWEDEN SHINING	A Taut Documentary of a Car And a Robot who must Conquer a Boy in The Canadian Rockies	2006	1	\N	6	4.99	176	19.99	PG	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'boy':16 'canadian':19 'car':8 'conquer':14 'documentari':5 'must':13 'robot':11 'rocki':20 'shine':2 'sweden':1 'taut':4
872	SWEET BROTHERHOOD	A Unbelieveable Epistle of a Sumo Wrestler And a Hunter who must Chase a Forensic Psychologist in A Baloon	2006	1	\N	3	2.99	185	27.99	R	2006-02-15 05:03:42	{"Deleted Scenes"}	'baloon':21 'brotherhood':2 'chase':15 'epistl':5 'forens':17 'hunter':12 'must':14 'psychologist':18 'sumo':8 'sweet':1 'unbeliev':4 'wrestler':9
873	SWEETHEARTS SUSPECTS	A Brilliant Character Study of a Frisbee And a Sumo Wrestler who must Confront a Woman in The Gulf of Mexico	2006	1	\N	3	0.99	108	13.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'brilliant':4 'charact':5 'confront':16 'frisbe':9 'gulf':21 'mexico':23 'must':15 'studi':6 'sumo':12 'suspect':2 'sweetheart':1 'woman':18 'wrestler':13
874	TADPOLE PARK	A Beautiful Tale of a Frisbee And a Moose who must Vanquish a Dog in An Abandoned Amusement Park	2006	1	\N	6	2.99	155	13.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries}	'abandon':19 'amus':20 'beauti':4 'dog':16 'frisbe':8 'moos':11 'must':13 'park':2,21 'tadpol':1 'tale':5 'vanquish':14
875	TALENTED HOMICIDE	A Lacklusture Panorama of a Dentist And a Forensic Psychologist who must Outrace a Pioneer in A U-Boat	2006	1	\N	6	0.99	173	9.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'boat':22 'dentist':8 'forens':11 'homicid':2 'lacklustur':4 'must':14 'outrac':15 'panorama':5 'pioneer':17 'psychologist':12 'talent':1 'u':21 'u-boat':20
876	TARZAN VIDEOTAPE	A Fast-Paced Display of a Lumberjack And a Mad Scientist who must Succumb a Sumo Wrestler in The Sahara Desert	2006	1	\N	3	2.99	91	11.99	PG-13	2006-02-15 05:03:42	{Trailers}	'desert':24 'display':7 'fast':5 'fast-pac':4 'lumberjack':10 'mad':13 'must':16 'pace':6 'sahara':23 'scientist':14 'succumb':17 'sumo':19 'tarzan':1 'videotap':2 'wrestler':20
877	TAXI KICK	A Amazing Epistle of a Girl And a Woman who must Outrace a Waitress in Soviet Georgia	2006	1	\N	4	0.99	64	23.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'amaz':4 'epistl':5 'georgia':19 'girl':8 'kick':2 'must':13 'outrac':14 'soviet':18 'taxi':1 'waitress':16 'woman':11
878	TEEN APOLLO	A Awe-Inspiring Drama of a Dog And a Man who must Escape a Robot in A Shark Tank	2006	1	\N	3	4.99	74	25.99	G	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'apollo':2 'awe':5 'awe-inspir':4 'dog':10 'drama':7 'escap':16 'inspir':6 'man':13 'must':15 'robot':18 'shark':21 'tank':22 'teen':1
879	TELEGRAPH VOYAGE	A Fateful Yarn of a Husband And a Dog who must Battle a Waitress in A Jet Boat	2006	1	\N	3	4.99	148	20.99	PG	2006-02-15 05:03:42	{Commentaries}	'battl':14 'boat':20 'dog':11 'fate':4 'husband':8 'jet':19 'must':13 'telegraph':1 'voyag':2 'waitress':16 'yarn':5
880	TELEMARK HEARTBREAKERS	A Action-Packed Panorama of a Technical Writer And a Man who must Build a Forensic Psychologist in A Manhattan Penthouse	2006	1	\N	6	2.99	152	9.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'action':5 'action-pack':4 'build':17 'forens':19 'heartbreak':2 'man':14 'manhattan':23 'must':16 'pack':6 'panorama':7 'penthous':24 'psychologist':20 'technic':10 'telemark':1 'writer':11
881	TEMPLE ATTRACTION	A Action-Packed Saga of a Forensic Psychologist And a Woman who must Battle a Womanizer in Soviet Georgia	2006	1	\N	5	4.99	71	13.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'action':5 'action-pack':4 'attract':2 'battl':17 'forens':10 'georgia':22 'must':16 'pack':6 'psychologist':11 'saga':7 'soviet':21 'templ':1 'woman':14,19
882	TENENBAUMS COMMAND	A Taut Display of a Pioneer And a Man who must Reach a Girl in The Gulf of Mexico	2006	1	\N	4	0.99	99	24.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'command':2 'display':5 'girl':16 'gulf':19 'man':11 'mexico':21 'must':13 'pioneer':8 'reach':14 'taut':4 'tenenbaum':1
883	TEQUILA PAST	A Action-Packed Panorama of a Mad Scientist And a Robot who must Challenge a Student in Nigeria	2006	1	\N	6	4.99	53	17.99	PG	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'action':5 'action-pack':4 'challeng':17 'mad':10 'must':16 'nigeria':21 'pack':6 'panorama':7 'past':2 'robot':14 'scientist':11 'student':19 'tequila':1
884	TERMINATOR CLUB	A Touching Story of a Crocodile And a Girl who must Sink a Man in The Gulf of Mexico	2006	1	\N	5	4.99	88	11.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'club':2 'crocodil':8 'girl':11 'gulf':19 'man':16 'mexico':21 'must':13 'sink':14 'stori':5 'termin':1 'touch':4
885	TEXAS WATCH	A Awe-Inspiring Yarn of a Student And a Teacher who must Fight a Teacher in An Abandoned Amusement Park	2006	1	\N	7	0.99	179	22.99	NC-17	2006-02-15 05:03:42	{Trailers}	'abandon':21 'amus':22 'awe':5 'awe-inspir':4 'fight':16 'inspir':6 'must':15 'park':23 'student':10 'teacher':13,18 'texa':1 'watch':2 'yarn':7
886	THEORY MERMAID	A Fateful Yarn of a Composer And a Monkey who must Vanquish a Womanizer in The First Manned Space Station	2006	1	\N	5	0.99	184	9.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'compos':8 'fate':4 'first':19 'man':20 'mermaid':2 'monkey':11 'must':13 'space':21 'station':22 'theori':1 'vanquish':14 'woman':16 'yarn':5
887	THIEF PELICAN	A Touching Documentary of a Madman And a Mad Scientist who must Outrace a Feminist in An Abandoned Mine Shaft	2006	1	\N	5	4.99	135	28.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'abandon':20 'documentari':5 'feminist':17 'mad':11 'madman':8 'mine':21 'must':14 'outrac':15 'pelican':2 'scientist':12 'shaft':22 'thief':1 'touch':4
888	THIN SAGEBRUSH	A Emotional Drama of a Husband And a Lumberjack who must Build a Cat in Ancient India	2006	1	\N	5	4.99	53	9.99	PG-13	2006-02-15 05:03:42	{"Behind the Scenes"}	'ancient':18 'build':14 'cat':16 'drama':5 'emot':4 'husband':8 'india':19 'lumberjack':11 'must':13 'sagebrush':2 'thin':1
889	TIES HUNGER	A Insightful Saga of a Astronaut And a Explorer who must Pursue a Mad Scientist in A U-Boat	2006	1	\N	3	4.99	111	28.99	R	2006-02-15 05:03:42	{"Deleted Scenes"}	'astronaut':8 'boat':22 'explor':11 'hunger':2 'insight':4 'mad':16 'must':13 'pursu':14 'saga':5 'scientist':17 'tie':1 'u':21 'u-boat':20
890	TIGHTS DAWN	A Thrilling Epistle of a Boat And a Secret Agent who must Face a Boy in A Baloon	2006	1	\N	5	0.99	172	14.99	R	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'agent':12 'baloon':20 'boat':8 'boy':17 'dawn':2 'epistl':5 'face':15 'must':14 'secret':11 'thrill':4 'tight':1
891	TIMBERLAND SKY	A Boring Display of a Man And a Dog who must Redeem a Girl in A U-Boat	2006	1	\N	3	0.99	69	13.99	G	2006-02-15 05:03:42	{Commentaries}	'boat':21 'bore':4 'display':5 'dog':11 'girl':16 'man':8 'must':13 'redeem':14 'sky':2 'timberland':1 'u':20 'u-boat':19
892	TITANIC BOONDOCK	A Brilliant Reflection of a Feminist And a Dog who must Fight a Boy in A Baloon Factory	2006	1	\N	3	4.99	104	18.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'baloon':19 'boondock':2 'boy':16 'brilliant':4 'dog':11 'factori':20 'feminist':8 'fight':14 'must':13 'reflect':5 'titan':1
893	TITANS JERK	A Unbelieveable Panorama of a Feminist And a Sumo Wrestler who must Challenge a Technical Writer in Ancient China	2006	1	\N	4	4.99	91	11.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'ancient':20 'challeng':15 'china':21 'feminist':8 'jerk':2 'must':14 'panorama':5 'sumo':11 'technic':17 'titan':1 'unbeliev':4 'wrestler':12 'writer':18
894	TOMATOES HELLFIGHTERS	A Thoughtful Epistle of a Madman And a Astronaut who must Overcome a Monkey in A Shark Tank	2006	1	\N	6	0.99	68	23.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'astronaut':11 'epistl':5 'hellfight':2 'madman':8 'monkey':16 'must':13 'overcom':14 'shark':19 'tank':20 'thought':4 'tomato':1
895	TOMORROW HUSTLER	A Thoughtful Story of a Moose And a Husband who must Face a Secret Agent in The Sahara Desert	2006	1	\N	3	2.99	142	21.99	R	2006-02-15 05:03:42	{Commentaries}	'agent':17 'desert':21 'face':14 'husband':11 'hustler':2 'moos':8 'must':13 'sahara':20 'secret':16 'stori':5 'thought':4 'tomorrow':1
896	TOOTSIE PILOT	A Awe-Inspiring Documentary of a Womanizer And a Pastry Chef who must Kill a Lumberjack in Berlin	2006	1	\N	3	0.99	157	10.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'awe':5 'awe-inspir':4 'berlin':21 'chef':14 'documentari':7 'inspir':6 'kill':17 'lumberjack':19 'must':16 'pastri':13 'pilot':2 'tootsi':1 'woman':10
897	TORQUE BOUND	A Emotional Display of a Crocodile And a Husband who must Reach a Man in Ancient Japan	2006	1	\N	3	4.99	179	27.99	G	2006-02-15 05:03:42	{Trailers,Commentaries}	'ancient':18 'bound':2 'crocodil':8 'display':5 'emot':4 'husband':11 'japan':19 'man':16 'must':13 'reach':14 'torqu':1
898	TOURIST PELICAN	A Boring Story of a Butler And a Astronaut who must Outrace a Pioneer in Australia	2006	1	\N	4	4.99	152	18.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'astronaut':11 'australia':18 'bore':4 'butler':8 'must':13 'outrac':14 'pelican':2 'pioneer':16 'stori':5 'tourist':1
899	TOWERS HURRICANE	A Fateful Display of a Monkey And a Car who must Sink a Husband in A MySQL Convention	2006	1	\N	7	0.99	144	14.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'car':11 'convent':20 'display':5 'fate':4 'hurrican':2 'husband':16 'monkey':8 'must':13 'mysql':19 'sink':14 'tower':1
900	TOWN ARK	A Awe-Inspiring Documentary of a Moose And a Madman who must Meet a Dog in An Abandoned Mine Shaft	2006	1	\N	6	2.99	136	17.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'abandon':21 'ark':2 'awe':5 'awe-inspir':4 'documentari':7 'dog':18 'inspir':6 'madman':13 'meet':16 'mine':22 'moos':10 'must':15 'shaft':23 'town':1
901	TRACY CIDER	A Touching Reflection of a Database Administrator And a Madman who must Build a Lumberjack in Nigeria	2006	1	\N	3	0.99	142	29.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'administr':9 'build':15 'cider':2 'databas':8 'lumberjack':17 'madman':12 'must':14 'nigeria':19 'reflect':5 'touch':4 'traci':1
902	TRADING PINOCCHIO	A Emotional Character Study of a Student And a Explorer who must Discover a Frisbee in The First Manned Space Station	2006	1	\N	6	4.99	170	22.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'charact':5 'discov':15 'emot':4 'explor':12 'first':20 'frisbe':17 'man':21 'must':14 'pinocchio':2 'space':22 'station':23 'student':9 'studi':6 'trade':1
903	TRAFFIC HOBBIT	A Amazing Epistle of a Squirrel And a Lumberjack who must Succumb a Database Administrator in A U-Boat	2006	1	\N	5	4.99	139	13.99	G	2006-02-15 05:03:42	{Trailers,Commentaries}	'administr':17 'amaz':4 'boat':22 'databas':16 'epistl':5 'hobbit':2 'lumberjack':11 'must':13 'squirrel':8 'succumb':14 'traffic':1 'u':21 'u-boat':20
904	TRAIN BUNCH	A Thrilling Character Study of a Robot And a Squirrel who must Face a Dog in Ancient India	2006	1	\N	3	4.99	71	26.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'ancient':19 'bunch':2 'charact':5 'dog':17 'face':15 'india':20 'must':14 'robot':9 'squirrel':12 'studi':6 'thrill':4 'train':1
905	TRAINSPOTTING STRANGERS	A Fast-Paced Drama of a Pioneer And a Mad Cow who must Challenge a Madman in Ancient Japan	2006	1	\N	7	4.99	132	10.99	PG-13	2006-02-15 05:03:42	{Trailers}	'ancient':21 'challeng':17 'cow':14 'drama':7 'fast':5 'fast-pac':4 'japan':22 'mad':13 'madman':19 'must':16 'pace':6 'pioneer':10 'stranger':2 'trainspot':1
906	TRAMP OTHERS	A Brilliant Display of a Composer And a Cat who must Succumb a A Shark in Ancient India	2006	1	\N	4	0.99	171	27.99	PG	2006-02-15 05:03:42	{"Deleted Scenes"}	'ancient':19 'brilliant':4 'cat':11 'compos':8 'display':5 'india':20 'must':13 'other':2 'shark':17 'succumb':14 'tramp':1
907	TRANSLATION SUMMER	A Touching Reflection of a Man And a Monkey who must Pursue a Womanizer in A MySQL Convention	2006	1	\N	4	0.99	168	10.99	PG-13	2006-02-15 05:03:42	{Trailers}	'convent':20 'man':8 'monkey':11 'must':13 'mysql':19 'pursu':14 'reflect':5 'summer':2 'touch':4 'translat':1 'woman':16
908	TRAP GUYS	A Unbelieveable Story of a Boy And a Mad Cow who must Challenge a Database Administrator in The Sahara Desert	2006	1	\N	3	4.99	110	11.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'administr':18 'boy':8 'challeng':15 'cow':12 'databas':17 'desert':22 'guy':2 'mad':11 'must':14 'sahara':21 'stori':5 'trap':1 'unbeliev':4
909	TREASURE COMMAND	A Emotional Saga of a Car And a Madman who must Discover a Pioneer in California	2006	1	\N	3	0.99	102	28.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'california':18 'car':8 'command':2 'discov':14 'emot':4 'madman':11 'must':13 'pioneer':16 'saga':5 'treasur':1
910	TREATMENT JEKYLL	A Boring Story of a Teacher And a Student who must Outgun a Cat in An Abandoned Mine Shaft	2006	1	\N	3	0.99	87	19.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'abandon':19 'bore':4 'cat':16 'jekyl':2 'mine':20 'must':13 'outgun':14 'shaft':21 'stori':5 'student':11 'teacher':8 'treatment':1
911	TRIP NEWTON	A Fanciful Character Study of a Lumberjack And a Car who must Discover a Cat in An Abandoned Amusement Park	2006	1	\N	7	4.99	64	14.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'abandon':20 'amus':21 'car':12 'cat':17 'charact':5 'discov':15 'fanci':4 'lumberjack':9 'must':14 'newton':2 'park':22 'studi':6 'trip':1
912	TROJAN TOMORROW	A Astounding Panorama of a Husband And a Sumo Wrestler who must Pursue a Boat in Ancient India	2006	1	\N	3	2.99	52	9.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'ancient':19 'astound':4 'boat':17 'husband':8 'india':20 'must':14 'panorama':5 'pursu':15 'sumo':11 'tomorrow':2 'trojan':1 'wrestler':12
913	TROOPERS METAL	A Fanciful Drama of a Monkey And a Feminist who must Sink a Man in Berlin	2006	1	\N	3	0.99	115	20.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'berlin':18 'drama':5 'fanci':4 'feminist':11 'man':16 'metal':2 'monkey':8 'must':13 'sink':14 'trooper':1
914	TROUBLE DATE	A Lacklusture Panorama of a Forensic Psychologist And a Woman who must Kill a Explorer in Ancient Japan	2006	1	\N	6	2.99	61	13.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'ancient':19 'date':2 'explor':17 'forens':8 'japan':20 'kill':15 'lacklustur':4 'must':14 'panorama':5 'psychologist':9 'troubl':1 'woman':12
915	TRUMAN CRAZY	A Thrilling Epistle of a Moose And a Boy who must Meet a Database Administrator in A Monastery	2006	1	\N	7	4.99	92	9.99	G	2006-02-15 05:03:42	{Trailers,Commentaries}	'administr':17 'boy':11 'crazi':2 'databas':16 'epistl':5 'meet':14 'monasteri':20 'moos':8 'must':13 'thrill':4 'truman':1
916	TURN STAR	A Stunning Tale of a Man And a Monkey who must Chase a Student in New Orleans	2006	1	\N	3	2.99	80	10.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'chase':14 'man':8 'monkey':11 'must':13 'new':18 'orlean':19 'star':2 'student':16 'stun':4 'tale':5 'turn':1
917	TUXEDO MILE	A Boring Drama of a Man And a Forensic Psychologist who must Face a Frisbee in Ancient India	2006	1	\N	3	2.99	152	24.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'ancient':19 'bore':4 'drama':5 'face':15 'forens':11 'frisbe':17 'india':20 'man':8 'mile':2 'must':14 'psychologist':12 'tuxedo':1
918	TWISTED PIRATES	A Touching Display of a Frisbee And a Boat who must Kill a Girl in A MySQL Convention	2006	1	\N	4	4.99	152	23.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'boat':11 'convent':20 'display':5 'frisbe':8 'girl':16 'kill':14 'must':13 'mysql':19 'pirat':2 'touch':4 'twist':1
919	TYCOON GATHERING	A Emotional Display of a Husband And a A Shark who must Succumb a Madman in A Manhattan Penthouse	2006	1	\N	3	4.99	82	17.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'display':5 'emot':4 'gather':2 'husband':8 'madman':17 'manhattan':20 'must':14 'penthous':21 'shark':12 'succumb':15 'tycoon':1
920	UNBREAKABLE KARATE	A Amazing Character Study of a Robot And a Student who must Chase a Robot in Australia	2006	1	\N	3	0.99	62	16.99	G	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'amaz':4 'australia':19 'charact':5 'chase':15 'karat':2 'must':14 'robot':9,17 'student':12 'studi':6 'unbreak':1
921	UNCUT SUICIDES	A Intrepid Yarn of a Explorer And a Pastry Chef who must Pursue a Mad Cow in A U-Boat	2006	1	\N	7	2.99	172	29.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'boat':23 'chef':12 'cow':18 'explor':8 'intrepid':4 'mad':17 'must':14 'pastri':11 'pursu':15 'suicid':2 'u':22 'u-boat':21 'uncut':1 'yarn':5
922	UNDEFEATED DALMATIONS	A Unbelieveable Display of a Crocodile And a Feminist who must Overcome a Moose in An Abandoned Amusement Park	2006	1	\N	7	4.99	107	22.99	PG-13	2006-02-15 05:03:42	{Commentaries}	'abandon':19 'amus':20 'crocodil':8 'dalmat':2 'display':5 'feminist':11 'moos':16 'must':13 'overcom':14 'park':21 'unbeliev':4 'undef':1
923	UNFAITHFUL KILL	A Taut Documentary of a Waitress And a Mad Scientist who must Battle a Technical Writer in New Orleans	2006	1	\N	7	2.99	78	12.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'battl':15 'documentari':5 'kill':2 'mad':11 'must':14 'new':20 'orlean':21 'scientist':12 'taut':4 'technic':17 'unfaith':1 'waitress':8 'writer':18
924	UNFORGIVEN ZOOLANDER	A Taut Epistle of a Monkey And a Sumo Wrestler who must Vanquish a A Shark in A Baloon Factory	2006	1	\N	7	0.99	129	15.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'baloon':21 'epistl':5 'factori':22 'monkey':8 'must':14 'shark':18 'sumo':11 'taut':4 'unforgiven':1 'vanquish':15 'wrestler':12 'zooland':2
925	UNITED PILOT	A Fast-Paced Reflection of a Cat And a Mad Cow who must Fight a Car in The Sahara Desert	2006	1	\N	3	0.99	164	27.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'car':19 'cat':10 'cow':14 'desert':23 'fast':5 'fast-pac':4 'fight':17 'mad':13 'must':16 'pace':6 'pilot':2 'reflect':7 'sahara':22 'unit':1
926	UNTOUCHABLES SUNRISE	A Amazing Documentary of a Woman And a Astronaut who must Outrace a Teacher in An Abandoned Fun House	2006	1	\N	5	2.99	120	11.99	NC-17	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'abandon':19 'amaz':4 'astronaut':11 'documentari':5 'fun':20 'hous':21 'must':13 'outrac':14 'sunris':2 'teacher':16 'untouch':1 'woman':8
927	UPRISING UPTOWN	A Fanciful Reflection of a Boy And a Butler who must Pursue a Woman in Berlin	2006	1	\N	6	2.99	174	16.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'berlin':18 'boy':8 'butler':11 'fanci':4 'must':13 'pursu':14 'reflect':5 'upris':1 'uptown':2 'woman':16
928	UPTOWN YOUNG	A Fateful Documentary of a Dog And a Hunter who must Pursue a Teacher in An Abandoned Amusement Park	2006	1	\N	5	2.99	84	16.99	PG	2006-02-15 05:03:42	{Commentaries}	'abandon':19 'amus':20 'documentari':5 'dog':8 'fate':4 'hunter':11 'must':13 'park':21 'pursu':14 'teacher':16 'uptown':1 'young':2
929	USUAL UNTOUCHABLES	A Touching Display of a Explorer And a Lumberjack who must Fight a Forensic Psychologist in A Shark Tank	2006	1	\N	5	4.99	128	21.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'display':5 'explor':8 'fight':14 'forens':16 'lumberjack':11 'must':13 'psychologist':17 'shark':20 'tank':21 'touch':4 'untouch':2 'usual':1
930	VACATION BOONDOCK	A Fanciful Character Study of a Secret Agent And a Mad Scientist who must Reach a Teacher in Australia	2006	1	\N	4	2.99	145	23.99	R	2006-02-15 05:03:42	{Commentaries}	'agent':10 'australia':21 'boondock':2 'charact':5 'fanci':4 'mad':13 'must':16 'reach':17 'scientist':14 'secret':9 'studi':6 'teacher':19 'vacat':1
931	VALENTINE VANISHING	A Thrilling Display of a Husband And a Butler who must Reach a Pastry Chef in California	2006	1	\N	7	0.99	48	9.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'butler':11 'california':19 'chef':17 'display':5 'husband':8 'must':13 'pastri':16 'reach':14 'thrill':4 'valentin':1 'vanish':2
932	VALLEY PACKER	A Astounding Documentary of a Astronaut And a Boy who must Outrace a Sumo Wrestler in Berlin	2006	1	\N	3	0.99	73	21.99	G	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'astound':4 'astronaut':8 'berlin':19 'boy':11 'documentari':5 'must':13 'outrac':14 'packer':2 'sumo':16 'valley':1 'wrestler':17
933	VAMPIRE WHALE	A Epic Story of a Lumberjack And a Monkey who must Confront a Pioneer in A MySQL Convention	2006	1	\N	4	4.99	126	11.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries}	'confront':14 'convent':20 'epic':4 'lumberjack':8 'monkey':11 'must':13 'mysql':19 'pioneer':16 'stori':5 'vampir':1 'whale':2
934	VANILLA DAY	A Fast-Paced Saga of a Girl And a Forensic Psychologist who must Redeem a Girl in Nigeria	2006	1	\N	7	4.99	122	20.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'day':2 'fast':5 'fast-pac':4 'forens':13 'girl':10,19 'must':16 'nigeria':21 'pace':6 'psychologist':14 'redeem':17 'saga':7 'vanilla':1
935	VANISHED GARDEN	A Intrepid Character Study of a Squirrel And a A Shark who must Kill a Lumberjack in California	2006	1	\N	5	0.99	142	17.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'california':20 'charact':5 'garden':2 'intrepid':4 'kill':16 'lumberjack':18 'must':15 'shark':13 'squirrel':9 'studi':6 'vanish':1
936	VANISHING ROCKY	A Brilliant Reflection of a Man And a Woman who must Conquer a Pioneer in A MySQL Convention	2006	1	\N	3	2.99	123	21.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'brilliant':4 'conquer':14 'convent':20 'man':8 'must':13 'mysql':19 'pioneer':16 'reflect':5 'rocki':2 'vanish':1 'woman':11
937	VARSITY TRIP	A Action-Packed Character Study of a Astronaut And a Explorer who must Reach a Monkey in A MySQL Convention	2006	1	\N	7	2.99	85	14.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'action':5 'action-pack':4 'astronaut':11 'charact':7 'convent':23 'explor':14 'monkey':19 'must':16 'mysql':22 'pack':6 'reach':17 'studi':8 'trip':2 'varsiti':1
938	VELVET TERMINATOR	A Lacklusture Tale of a Pastry Chef And a Technical Writer who must Confront a Crocodile in An Abandoned Amusement Park	2006	1	\N	3	4.99	173	14.99	R	2006-02-15 05:03:42	{"Behind the Scenes"}	'abandon':21 'amus':22 'chef':9 'confront':16 'crocodil':18 'lacklustur':4 'must':15 'park':23 'pastri':8 'tale':5 'technic':12 'termin':2 'velvet':1 'writer':13
939	VERTIGO NORTHWEST	A Unbelieveable Display of a Mad Scientist And a Mad Scientist who must Outgun a Mad Cow in Ancient Japan	2006	1	\N	4	2.99	90	17.99	R	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'ancient':21 'cow':19 'display':5 'japan':22 'mad':8,12,18 'must':15 'northwest':2 'outgun':16 'scientist':9,13 'unbeliev':4 'vertigo':1
940	VICTORY ACADEMY	A Insightful Epistle of a Mad Scientist And a Explorer who must Challenge a Cat in The Sahara Desert	2006	1	\N	6	0.99	64	19.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'academi':2 'cat':17 'challeng':15 'desert':21 'epistl':5 'explor':12 'insight':4 'mad':8 'must':14 'sahara':20 'scientist':9 'victori':1
941	VIDEOTAPE ARSENIC	A Lacklusture Display of a Girl And a Astronaut who must Succumb a Student in Australia	2006	1	\N	4	4.99	145	10.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'arsenic':2 'astronaut':11 'australia':18 'display':5 'girl':8 'lacklustur':4 'must':13 'student':16 'succumb':14 'videotap':1
942	VIETNAM SMOOCHY	A Lacklusture Display of a Butler And a Man who must Sink a Explorer in Soviet Georgia	2006	1	\N	7	0.99	174	27.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'butler':8 'display':5 'explor':16 'georgia':19 'lacklustur':4 'man':11 'must':13 'sink':14 'smoochi':2 'soviet':18 'vietnam':1
943	VILLAIN DESPERATE	A Boring Yarn of a Pioneer And a Feminist who must Redeem a Cat in An Abandoned Amusement Park	2006	1	\N	4	4.99	76	27.99	PG-13	2006-02-15 05:03:42	{Trailers,Commentaries}	'abandon':19 'amus':20 'bore':4 'cat':16 'desper':2 'feminist':11 'must':13 'park':21 'pioneer':8 'redeem':14 'villain':1 'yarn':5
944	VIRGIN DAISY	A Awe-Inspiring Documentary of a Robot And a Mad Scientist who must Reach a Database Administrator in A Shark Tank	2006	1	\N	6	4.99	179	29.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'administr':20 'awe':5 'awe-inspir':4 'daisi':2 'databas':19 'documentari':7 'inspir':6 'mad':13 'must':16 'reach':17 'robot':10 'scientist':14 'shark':23 'tank':24 'virgin':1
945	VIRGINIAN PLUTO	A Emotional Panorama of a Dentist And a Crocodile who must Meet a Boy in Berlin	2006	1	\N	5	0.99	164	22.99	R	2006-02-15 05:03:42	{"Deleted Scenes"}	'berlin':18 'boy':16 'crocodil':11 'dentist':8 'emot':4 'meet':14 'must':13 'panorama':5 'pluto':2 'virginian':1
946	VIRTUAL SPOILERS	A Fateful Tale of a Database Administrator And a Squirrel who must Discover a Student in Soviet Georgia	2006	1	\N	3	4.99	144	14.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'administr':9 'databas':8 'discov':15 'fate':4 'georgia':20 'must':14 'soviet':19 'spoiler':2 'squirrel':12 'student':17 'tale':5 'virtual':1
947	VISION TORQUE	A Thoughtful Documentary of a Dog And a Man who must Sink a Man in A Shark Tank	2006	1	\N	5	0.99	59	16.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'documentari':5 'dog':8 'man':11,16 'must':13 'shark':19 'sink':14 'tank':20 'thought':4 'torqu':2 'vision':1
948	VOICE PEACH	A Amazing Panorama of a Pioneer And a Student who must Overcome a Mad Scientist in A Manhattan Penthouse	2006	1	\N	6	0.99	139	22.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'amaz':4 'mad':16 'manhattan':20 'must':13 'overcom':14 'panorama':5 'peach':2 'penthous':21 'pioneer':8 'scientist':17 'student':11 'voic':1
949	VOLCANO TEXAS	A Awe-Inspiring Yarn of a Hunter And a Feminist who must Challenge a Dentist in The Outback	2006	1	\N	6	0.99	157	27.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'awe':5 'awe-inspir':4 'challeng':16 'dentist':18 'feminist':13 'hunter':10 'inspir':6 'must':15 'outback':21 'texa':2 'volcano':1 'yarn':7
950	VOLUME HOUSE	A Boring Tale of a Dog And a Woman who must Meet a Dentist in California	2006	1	\N	7	4.99	132	12.99	PG	2006-02-15 05:03:42	{Commentaries}	'bore':4 'california':18 'dentist':16 'dog':8 'hous':2 'meet':14 'must':13 'tale':5 'volum':1 'woman':11
951	VOYAGE LEGALLY	A Epic Tale of a Squirrel And a Hunter who must Conquer a Boy in An Abandoned Mine Shaft	2006	1	\N	6	0.99	78	28.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'abandon':19 'boy':16 'conquer':14 'epic':4 'hunter':11 'legal':2 'mine':20 'must':13 'shaft':21 'squirrel':8 'tale':5 'voyag':1
952	WAGON JAWS	A Intrepid Drama of a Moose And a Boat who must Kill a Explorer in A Manhattan Penthouse	2006	1	\N	7	2.99	152	17.99	PG	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'boat':11 'drama':5 'explor':16 'intrepid':4 'jaw':2 'kill':14 'manhattan':19 'moos':8 'must':13 'penthous':20 'wagon':1
953	WAIT CIDER	A Intrepid Epistle of a Woman And a Forensic Psychologist who must Succumb a Astronaut in A Manhattan Penthouse	2006	1	\N	3	0.99	112	9.99	PG-13	2006-02-15 05:03:42	{Trailers}	'astronaut':17 'cider':2 'epistl':5 'forens':11 'intrepid':4 'manhattan':20 'must':14 'penthous':21 'psychologist':12 'succumb':15 'wait':1 'woman':8
954	WAKE JAWS	A Beautiful Saga of a Feminist And a Composer who must Challenge a Moose in Berlin	2006	1	\N	7	4.99	73	18.99	G	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'beauti':4 'berlin':18 'challeng':14 'compos':11 'feminist':8 'jaw':2 'moos':16 'must':13 'saga':5 'wake':1
955	WALLS ARTIST	A Insightful Panorama of a Teacher And a Teacher who must Overcome a Mad Cow in An Abandoned Fun House	2006	1	\N	7	4.99	135	19.99	PG	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'abandon':20 'artist':2 'cow':17 'fun':21 'hous':22 'insight':4 'mad':16 'must':13 'overcom':14 'panorama':5 'teacher':8,11 'wall':1
956	WANDA CHAMBER	A Insightful Drama of a A Shark And a Pioneer who must Find a Womanizer in The Outback	2006	1	\N	7	4.99	107	23.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'chamber':2 'drama':5 'find':15 'insight':4 'must':14 'outback':20 'pioneer':12 'shark':9 'wanda':1 'woman':17
957	WAR NOTTING	A Boring Drama of a Teacher And a Sumo Wrestler who must Challenge a Secret Agent in The Canadian Rockies	2006	1	\N	7	4.99	80	26.99	G	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'agent':18 'bore':4 'canadian':21 'challeng':15 'drama':5 'must':14 'not':2 'rocki':22 'secret':17 'sumo':11 'teacher':8 'war':1 'wrestler':12
958	WARDROBE PHANTOM	A Action-Packed Display of a Mad Cow And a Astronaut who must Kill a Car in Ancient India	2006	1	\N	6	2.99	178	19.99	G	2006-02-15 05:03:42	{Trailers,Commentaries}	'action':5 'action-pack':4 'ancient':21 'astronaut':14 'car':19 'cow':11 'display':7 'india':22 'kill':17 'mad':10 'must':16 'pack':6 'phantom':2 'wardrob':1
959	WARLOCK WEREWOLF	A Astounding Yarn of a Pioneer And a Crocodile who must Defeat a A Shark in The Outback	2006	1	\N	6	2.99	83	10.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'astound':4 'crocodil':11 'defeat':14 'must':13 'outback':20 'pioneer':8 'shark':17 'warlock':1 'werewolf':2 'yarn':5
960	WARS PLUTO	A Taut Reflection of a Teacher And a Database Administrator who must Chase a Madman in The Sahara Desert	2006	1	\N	5	2.99	128	15.99	G	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'administr':12 'chase':15 'databas':11 'desert':21 'madman':17 'must':14 'pluto':2 'reflect':5 'sahara':20 'taut':4 'teacher':8 'war':1
961	WASH HEAVENLY	A Awe-Inspiring Reflection of a Cat And a Pioneer who must Escape a Hunter in Ancient China	2006	1	\N	7	4.99	161	22.99	R	2006-02-15 05:03:42	{Commentaries}	'ancient':20 'awe':5 'awe-inspir':4 'cat':10 'china':21 'escap':16 'heaven':2 'hunter':18 'inspir':6 'must':15 'pioneer':13 'reflect':7 'wash':1
962	WASTELAND DIVINE	A Fanciful Story of a Database Administrator And a Womanizer who must Fight a Database Administrator in Ancient China	2006	1	\N	7	2.99	85	18.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'administr':9,18 'ancient':20 'china':21 'databas':8,17 'divin':2 'fanci':4 'fight':15 'must':14 'stori':5 'wasteland':1 'woman':12
963	WATCH TRACY	A Fast-Paced Yarn of a Dog And a Frisbee who must Conquer a Hunter in Nigeria	2006	1	\N	5	0.99	78	12.99	PG	2006-02-15 05:03:42	{Trailers,"Deleted Scenes","Behind the Scenes"}	'conquer':16 'dog':10 'fast':5 'fast-pac':4 'frisbe':13 'hunter':18 'must':15 'nigeria':20 'pace':6 'traci':2 'watch':1 'yarn':7
964	WATERFRONT DELIVERANCE	A Unbelieveable Documentary of a Dentist And a Technical Writer who must Build a Womanizer in Nigeria	2006	1	\N	4	4.99	61	17.99	G	2006-02-15 05:03:42	{"Behind the Scenes"}	'build':15 'deliver':2 'dentist':8 'documentari':5 'must':14 'nigeria':19 'technic':11 'unbeliev':4 'waterfront':1 'woman':17 'writer':12
965	WATERSHIP FRONTIER	A Emotional Yarn of a Boat And a Crocodile who must Meet a Moose in Soviet Georgia	2006	1	\N	6	0.99	112	28.99	G	2006-02-15 05:03:42	{Commentaries}	'boat':8 'crocodil':11 'emot':4 'frontier':2 'georgia':19 'meet':14 'moos':16 'must':13 'soviet':18 'watership':1 'yarn':5
966	WEDDING APOLLO	A Action-Packed Tale of a Student And a Waitress who must Conquer a Lumberjack in An Abandoned Mine Shaft	2006	1	\N	3	0.99	70	14.99	PG	2006-02-15 05:03:42	{Trailers}	'abandon':21 'action':5 'action-pack':4 'apollo':2 'conquer':16 'lumberjack':18 'mine':22 'must':15 'pack':6 'shaft':23 'student':10 'tale':7 'waitress':13 'wed':1
967	WEEKEND PERSONAL	A Fast-Paced Documentary of a Car And a Butler who must Find a Frisbee in A Jet Boat	2006	1	\N	5	2.99	134	26.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'boat':22 'butler':13 'car':10 'documentari':7 'fast':5 'fast-pac':4 'find':16 'frisbe':18 'jet':21 'must':15 'pace':6 'person':2 'weekend':1
968	WEREWOLF LOLA	A Fanciful Story of a Man And a Sumo Wrestler who must Outrace a Student in A Monastery	2006	1	\N	6	4.99	79	19.99	G	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'fanci':4 'lola':2 'man':8 'monasteri':20 'must':14 'outrac':15 'stori':5 'student':17 'sumo':11 'werewolf':1 'wrestler':12
969	WEST LION	A Intrepid Drama of a Butler And a Lumberjack who must Challenge a Database Administrator in A Manhattan Penthouse	2006	1	\N	4	4.99	159	29.99	G	2006-02-15 05:03:42	{Trailers}	'administr':17 'butler':8 'challeng':14 'databas':16 'drama':5 'intrepid':4 'lion':2 'lumberjack':11 'manhattan':20 'must':13 'penthous':21 'west':1
970	WESTWARD SEABISCUIT	A Lacklusture Tale of a Butler And a Husband who must Face a Boy in Ancient China	2006	1	\N	7	0.99	52	11.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'ancient':18 'boy':16 'butler':8 'china':19 'face':14 'husband':11 'lacklustur':4 'must':13 'seabiscuit':2 'tale':5 'westward':1
971	WHALE BIKINI	A Intrepid Story of a Pastry Chef And a Database Administrator who must Kill a Feminist in A MySQL Convention	2006	1	\N	4	4.99	109	11.99	PG-13	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'administr':13 'bikini':2 'chef':9 'convent':22 'databas':12 'feminist':18 'intrepid':4 'kill':16 'must':15 'mysql':21 'pastri':8 'stori':5 'whale':1
972	WHISPERER GIANT	A Intrepid Story of a Dentist And a Hunter who must Confront a Monkey in Ancient Japan	2006	1	\N	4	4.99	59	24.99	PG-13	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'ancient':18 'confront':14 'dentist':8 'giant':2 'hunter':11 'intrepid':4 'japan':19 'monkey':16 'must':13 'stori':5 'whisper':1
973	WIFE TURN	A Awe-Inspiring Epistle of a Teacher And a Feminist who must Confront a Pioneer in Ancient Japan	2006	1	\N	3	4.99	183	27.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'ancient':20 'awe':5 'awe-inspir':4 'confront':16 'epistl':7 'feminist':13 'inspir':6 'japan':21 'must':15 'pioneer':18 'teacher':10 'turn':2 'wife':1
974	WILD APOLLO	A Beautiful Story of a Monkey And a Sumo Wrestler who must Conquer a A Shark in A MySQL Convention	2006	1	\N	4	0.99	181	24.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes","Behind the Scenes"}	'apollo':2 'beauti':4 'conquer':15 'convent':22 'monkey':8 'must':14 'mysql':21 'shark':18 'stori':5 'sumo':11 'wild':1 'wrestler':12
975	WILLOW TRACY	A Brilliant Panorama of a Boat And a Astronaut who must Challenge a Teacher in A Manhattan Penthouse	2006	1	\N	6	2.99	137	22.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'astronaut':11 'boat':8 'brilliant':4 'challeng':14 'manhattan':19 'must':13 'panorama':5 'penthous':20 'teacher':16 'traci':2 'willow':1
976	WIND PHANTOM	A Touching Saga of a Madman And a Forensic Psychologist who must Build a Sumo Wrestler in An Abandoned Mine Shaft	2006	1	\N	6	0.99	111	12.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'abandon':21 'build':15 'forens':11 'madman':8 'mine':22 'must':14 'phantom':2 'psychologist':12 'saga':5 'shaft':23 'sumo':17 'touch':4 'wind':1 'wrestler':18
977	WINDOW SIDE	A Astounding Character Study of a Womanizer And a Hunter who must Escape a Robot in A Monastery	2006	1	\N	3	2.99	85	25.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'astound':4 'charact':5 'escap':15 'hunter':12 'monasteri':20 'must':14 'robot':17 'side':2 'studi':6 'window':1 'woman':9
978	WISDOM WORKER	A Unbelieveable Saga of a Forensic Psychologist And a Student who must Face a Squirrel in The First Manned Space Station	2006	1	\N	3	0.99	98	12.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'face':15 'first':20 'forens':8 'man':21 'must':14 'psychologist':9 'saga':5 'space':22 'squirrel':17 'station':23 'student':12 'unbeliev':4 'wisdom':1 'worker':2
979	WITCHES PANIC	A Awe-Inspiring Drama of a Secret Agent And a Hunter who must Fight a Moose in Nigeria	2006	1	\N	6	4.99	100	10.99	NC-17	2006-02-15 05:03:42	{Commentaries,"Behind the Scenes"}	'agent':11 'awe':5 'awe-inspir':4 'drama':7 'fight':17 'hunter':14 'inspir':6 'moos':19 'must':16 'nigeria':21 'panic':2 'secret':10 'witch':1
980	WIZARD COLDBLOODED	A Lacklusture Display of a Robot And a Girl who must Defeat a Sumo Wrestler in A MySQL Convention	2006	1	\N	4	4.99	75	12.99	PG	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes","Behind the Scenes"}	'coldblood':2 'convent':21 'defeat':14 'display':5 'girl':11 'lacklustur':4 'must':13 'mysql':20 'robot':8 'sumo':16 'wizard':1 'wrestler':17
981	WOLVES DESIRE	A Fast-Paced Drama of a Squirrel And a Robot who must Succumb a Technical Writer in A Manhattan Penthouse	2006	1	\N	7	0.99	55	13.99	NC-17	2006-02-15 05:03:42	{"Behind the Scenes"}	'desir':2 'drama':7 'fast':5 'fast-pac':4 'manhattan':22 'must':15 'pace':6 'penthous':23 'robot':13 'squirrel':10 'succumb':16 'technic':18 'wolv':1 'writer':19
982	WOMEN DORADO	A Insightful Documentary of a Waitress And a Butler who must Vanquish a Composer in Australia	2006	1	\N	4	0.99	126	23.99	R	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'australia':18 'butler':11 'compos':16 'documentari':5 'dorado':2 'insight':4 'must':13 'vanquish':14 'waitress':8 'women':1
983	WON DARES	A Unbelieveable Documentary of a Teacher And a Monkey who must Defeat a Explorer in A U-Boat	2006	1	\N	7	2.99	105	18.99	PG	2006-02-15 05:03:42	{"Behind the Scenes"}	'boat':21 'dare':2 'defeat':14 'documentari':5 'explor':16 'monkey':11 'must':13 'teacher':8 'u':20 'u-boat':19 'unbeliev':4 'won':1
984	WONDERFUL DROP	A Boring Panorama of a Woman And a Madman who must Overcome a Butler in A U-Boat	2006	1	\N	3	2.99	126	20.99	NC-17	2006-02-15 05:03:42	{Commentaries}	'boat':21 'bore':4 'butler':16 'drop':2 'madman':11 'must':13 'overcom':14 'panorama':5 'u':20 'u-boat':19 'woman':8 'wonder':1
985	WONDERLAND CHRISTMAS	A Awe-Inspiring Character Study of a Waitress And a Car who must Pursue a Mad Scientist in The First Manned Space Station	2006	1	\N	4	4.99	111	19.99	PG	2006-02-15 05:03:42	{Commentaries}	'awe':5 'awe-inspir':4 'car':14 'charact':7 'christma':2 'first':23 'inspir':6 'mad':19 'man':24 'must':16 'pursu':17 'scientist':20 'space':25 'station':26 'studi':8 'waitress':11 'wonderland':1
986	WONKA SEA	A Brilliant Saga of a Boat And a Mad Scientist who must Meet a Moose in Ancient India	2006	1	\N	6	2.99	85	24.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries}	'ancient':19 'boat':8 'brilliant':4 'india':20 'mad':11 'meet':15 'moos':17 'must':14 'saga':5 'scientist':12 'sea':2 'wonka':1
987	WORDS HUNTER	A Action-Packed Reflection of a Composer And a Mad Scientist who must Face a Pioneer in A MySQL Convention	2006	1	\N	3	2.99	116	13.99	PG	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'action':5 'action-pack':4 'compos':10 'convent':23 'face':17 'hunter':2 'mad':13 'must':16 'mysql':22 'pack':6 'pioneer':19 'reflect':7 'scientist':14 'word':1
988	WORKER TARZAN	A Action-Packed Yarn of a Secret Agent And a Technical Writer who must Battle a Sumo Wrestler in The First Manned Space Station	2006	1	\N	7	2.99	139	26.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'action':5 'action-pack':4 'agent':11 'battl':18 'first':24 'man':25 'must':17 'pack':6 'secret':10 'space':26 'station':27 'sumo':20 'tarzan':2 'technic':14 'worker':1 'wrestler':21 'writer':15 'yarn':7
989	WORKING MICROCOSMOS	A Stunning Epistle of a Dentist And a Dog who must Kill a Madman in Ancient China	2006	1	\N	4	4.99	74	22.99	R	2006-02-15 05:03:42	{Commentaries,"Deleted Scenes"}	'ancient':18 'china':19 'dentist':8 'dog':11 'epistl':5 'kill':14 'madman':16 'microcosmo':2 'must':13 'stun':4 'work':1
990	WORLD LEATHERNECKS	A Unbelieveable Tale of a Pioneer And a Astronaut who must Overcome a Robot in An Abandoned Amusement Park	2006	1	\N	3	0.99	171	13.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'abandon':19 'amus':20 'astronaut':11 'leatherneck':2 'must':13 'overcom':14 'park':21 'pioneer':8 'robot':16 'tale':5 'unbeliev':4 'world':1
991	WORST BANGER	A Thrilling Drama of a Madman And a Dentist who must Conquer a Boy in The Outback	2006	1	\N	4	2.99	185	26.99	PG	2006-02-15 05:03:42	{"Deleted Scenes","Behind the Scenes"}	'banger':2 'boy':16 'conquer':14 'dentist':11 'drama':5 'madman':8 'must':13 'outback':19 'thrill':4 'worst':1
992	WRATH MILE	A Intrepid Reflection of a Technical Writer And a Hunter who must Defeat a Sumo Wrestler in A Monastery	2006	1	\N	5	0.99	176	17.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries}	'defeat':15 'hunter':12 'intrepid':4 'mile':2 'monasteri':21 'must':14 'reflect':5 'sumo':17 'technic':8 'wrath':1 'wrestler':18 'writer':9
993	WRONG BEHAVIOR	A Emotional Saga of a Crocodile And a Sumo Wrestler who must Discover a Mad Cow in New Orleans	2006	1	\N	6	2.99	178	10.99	PG-13	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'behavior':2 'cow':18 'crocodil':8 'discov':15 'emot':4 'mad':17 'must':14 'new':20 'orlean':21 'saga':5 'sumo':11 'wrestler':12 'wrong':1
994	WYOMING STORM	A Awe-Inspiring Panorama of a Robot And a Boat who must Overcome a Feminist in A U-Boat	2006	1	\N	6	4.99	100	29.99	PG-13	2006-02-15 05:03:42	{"Deleted Scenes"}	'awe':5 'awe-inspir':4 'boat':13,23 'feminist':18 'inspir':6 'must':15 'overcom':16 'panorama':7 'robot':10 'storm':2 'u':22 'u-boat':21 'wyom':1
995	YENTL IDAHO	A Amazing Display of a Robot And a Astronaut who must Fight a Womanizer in Berlin	2006	1	\N	5	4.99	86	11.99	R	2006-02-15 05:03:42	{Trailers,Commentaries,"Deleted Scenes"}	'amaz':4 'astronaut':11 'berlin':18 'display':5 'fight':14 'idaho':2 'must':13 'robot':8 'woman':16 'yentl':1
996	YOUNG LANGUAGE	A Unbelieveable Yarn of a Boat And a Database Administrator who must Meet a Boy in The First Manned Space Station	2006	1	\N	6	0.99	183	9.99	G	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'administr':12 'boat':8 'boy':17 'databas':11 'first':20 'languag':2 'man':21 'meet':15 'must':14 'space':22 'station':23 'unbeliev':4 'yarn':5 'young':1
997	YOUTH KICK	A Touching Drama of a Teacher And a Cat who must Challenge a Technical Writer in A U-Boat	2006	1	\N	4	0.99	179	14.99	NC-17	2006-02-15 05:03:42	{Trailers,"Behind the Scenes"}	'boat':22 'cat':11 'challeng':14 'drama':5 'kick':2 'must':13 'teacher':8 'technic':16 'touch':4 'u':21 'u-boat':20 'writer':17 'youth':1
998	ZHIVAGO CORE	A Fateful Yarn of a Composer And a Man who must Face a Boy in The Canadian Rockies	2006	1	\N	6	0.99	105	10.99	NC-17	2006-02-15 05:03:42	{"Deleted Scenes"}	'boy':16 'canadian':19 'compos':8 'core':2 'face':14 'fate':4 'man':11 'must':13 'rocki':20 'yarn':5 'zhivago':1
999	ZOOLANDER FICTION	A Fateful Reflection of a Waitress And a Boat who must Discover a Sumo Wrestler in Ancient China	2006	1	\N	5	2.99	101	28.99	R	2006-02-15 05:03:42	{Trailers,"Deleted Scenes"}	'ancient':19 'boat':11 'china':20 'discov':14 'fate':4 'fiction':2 'must':13 'reflect':5 'sumo':16 'waitress':8 'wrestler':17 'zooland':1
1000	ZORRO ARK	A Intrepid Panorama of a Mad Scientist And a Boy who must Redeem a Boy in A Monastery	2006	1	\N	3	4.99	50	18.99	NC-17	2006-02-15 05:03:42	{Trailers,Commentaries,"Behind the Scenes"}	'ark':2 'boy':12,17 'intrepid':4 'mad':8 'monasteri':20 'must':14 'panorama':5 'redeem':15 'scientist':9 'zorro':1
\.


--
-- Data for Name: film_actor; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.film_actor (actor_id, film_id, last_update) FROM stdin;
1	1	2006-02-15 05:05:03
1	23	2006-02-15 05:05:03
1	25	2006-02-15 05:05:03
1	106	2006-02-15 05:05:03
1	140	2006-02-15 05:05:03
1	166	2006-02-15 05:05:03
1	277	2006-02-15 05:05:03
1	361	2006-02-15 05:05:03
1	438	2006-02-15 05:05:03
1	499	2006-02-15 05:05:03
1	506	2006-02-15 05:05:03
1	509	2006-02-15 05:05:03
1	605	2006-02-15 05:05:03
1	635	2006-02-15 05:05:03
1	749	2006-02-15 05:05:03
1	832	2006-02-15 05:05:03
1	939	2006-02-15 05:05:03
1	970	2006-02-15 05:05:03
1	980	2006-02-15 05:05:03
2	3	2006-02-15 05:05:03
2	31	2006-02-15 05:05:03
2	47	2006-02-15 05:05:03
2	105	2006-02-15 05:05:03
2	132	2006-02-15 05:05:03
2	145	2006-02-15 05:05:03
2	226	2006-02-15 05:05:03
2	249	2006-02-15 05:05:03
2	314	2006-02-15 05:05:03
2	321	2006-02-15 05:05:03
2	357	2006-02-15 05:05:03
2	369	2006-02-15 05:05:03
2	399	2006-02-15 05:05:03
2	458	2006-02-15 05:05:03
2	481	2006-02-15 05:05:03
2	485	2006-02-15 05:05:03
2	518	2006-02-15 05:05:03
2	540	2006-02-15 05:05:03
2	550	2006-02-15 05:05:03
2	555	2006-02-15 05:05:03
2	561	2006-02-15 05:05:03
2	742	2006-02-15 05:05:03
2	754	2006-02-15 05:05:03
2	811	2006-02-15 05:05:03
2	958	2006-02-15 05:05:03
3	17	2006-02-15 05:05:03
3	40	2006-02-15 05:05:03
3	42	2006-02-15 05:05:03
3	87	2006-02-15 05:05:03
3	111	2006-02-15 05:05:03
3	185	2006-02-15 05:05:03
3	289	2006-02-15 05:05:03
3	329	2006-02-15 05:05:03
3	336	2006-02-15 05:05:03
3	341	2006-02-15 05:05:03
3	393	2006-02-15 05:05:03
3	441	2006-02-15 05:05:03
3	453	2006-02-15 05:05:03
3	480	2006-02-15 05:05:03
3	539	2006-02-15 05:05:03
3	618	2006-02-15 05:05:03
3	685	2006-02-15 05:05:03
3	827	2006-02-15 05:05:03
3	966	2006-02-15 05:05:03
3	967	2006-02-15 05:05:03
3	971	2006-02-15 05:05:03
3	996	2006-02-15 05:05:03
4	23	2006-02-15 05:05:03
4	25	2006-02-15 05:05:03
4	56	2006-02-15 05:05:03
4	62	2006-02-15 05:05:03
4	79	2006-02-15 05:05:03
4	87	2006-02-15 05:05:03
4	355	2006-02-15 05:05:03
4	379	2006-02-15 05:05:03
4	398	2006-02-15 05:05:03
4	463	2006-02-15 05:05:03
4	490	2006-02-15 05:05:03
4	616	2006-02-15 05:05:03
4	635	2006-02-15 05:05:03
4	691	2006-02-15 05:05:03
4	712	2006-02-15 05:05:03
4	714	2006-02-15 05:05:03
4	721	2006-02-15 05:05:03
4	798	2006-02-15 05:05:03
4	832	2006-02-15 05:05:03
4	858	2006-02-15 05:05:03
4	909	2006-02-15 05:05:03
4	924	2006-02-15 05:05:03
5	19	2006-02-15 05:05:03
5	54	2006-02-15 05:05:03
5	85	2006-02-15 05:05:03
5	146	2006-02-15 05:05:03
5	171	2006-02-15 05:05:03
5	172	2006-02-15 05:05:03
5	202	2006-02-15 05:05:03
5	203	2006-02-15 05:05:03
5	286	2006-02-15 05:05:03
5	288	2006-02-15 05:05:03
5	316	2006-02-15 05:05:03
5	340	2006-02-15 05:05:03
5	369	2006-02-15 05:05:03
5	375	2006-02-15 05:05:03
5	383	2006-02-15 05:05:03
5	392	2006-02-15 05:05:03
5	411	2006-02-15 05:05:03
5	503	2006-02-15 05:05:03
5	535	2006-02-15 05:05:03
5	571	2006-02-15 05:05:03
5	650	2006-02-15 05:05:03
5	665	2006-02-15 05:05:03
5	687	2006-02-15 05:05:03
5	730	2006-02-15 05:05:03
5	732	2006-02-15 05:05:03
5	811	2006-02-15 05:05:03
5	817	2006-02-15 05:05:03
5	841	2006-02-15 05:05:03
5	865	2006-02-15 05:05:03
6	29	2006-02-15 05:05:03
6	53	2006-02-15 05:05:03
6	60	2006-02-15 05:05:03
6	70	2006-02-15 05:05:03
6	112	2006-02-15 05:05:03
6	164	2006-02-15 05:05:03
6	165	2006-02-15 05:05:03
6	193	2006-02-15 05:05:03
6	256	2006-02-15 05:05:03
6	451	2006-02-15 05:05:03
6	503	2006-02-15 05:05:03
6	509	2006-02-15 05:05:03
6	517	2006-02-15 05:05:03
6	519	2006-02-15 05:05:03
6	605	2006-02-15 05:05:03
6	692	2006-02-15 05:05:03
6	826	2006-02-15 05:05:03
6	892	2006-02-15 05:05:03
6	902	2006-02-15 05:05:03
6	994	2006-02-15 05:05:03
7	25	2006-02-15 05:05:03
7	27	2006-02-15 05:05:03
7	35	2006-02-15 05:05:03
7	67	2006-02-15 05:05:03
7	96	2006-02-15 05:05:03
7	170	2006-02-15 05:05:03
7	173	2006-02-15 05:05:03
7	217	2006-02-15 05:05:03
7	218	2006-02-15 05:05:03
7	225	2006-02-15 05:05:03
7	292	2006-02-15 05:05:03
7	351	2006-02-15 05:05:03
7	414	2006-02-15 05:05:03
7	463	2006-02-15 05:05:03
7	554	2006-02-15 05:05:03
7	618	2006-02-15 05:05:03
7	633	2006-02-15 05:05:03
7	637	2006-02-15 05:05:03
7	691	2006-02-15 05:05:03
7	758	2006-02-15 05:05:03
7	766	2006-02-15 05:05:03
7	770	2006-02-15 05:05:03
7	805	2006-02-15 05:05:03
7	806	2006-02-15 05:05:03
7	846	2006-02-15 05:05:03
7	900	2006-02-15 05:05:03
7	901	2006-02-15 05:05:03
7	910	2006-02-15 05:05:03
7	957	2006-02-15 05:05:03
7	959	2006-02-15 05:05:03
8	47	2006-02-15 05:05:03
8	115	2006-02-15 05:05:03
8	158	2006-02-15 05:05:03
8	179	2006-02-15 05:05:03
8	195	2006-02-15 05:05:03
8	205	2006-02-15 05:05:03
8	255	2006-02-15 05:05:03
8	263	2006-02-15 05:05:03
8	321	2006-02-15 05:05:03
8	396	2006-02-15 05:05:03
8	458	2006-02-15 05:05:03
8	523	2006-02-15 05:05:03
8	532	2006-02-15 05:05:03
8	554	2006-02-15 05:05:03
8	752	2006-02-15 05:05:03
8	769	2006-02-15 05:05:03
8	771	2006-02-15 05:05:03
8	859	2006-02-15 05:05:03
8	895	2006-02-15 05:05:03
8	936	2006-02-15 05:05:03
9	30	2006-02-15 05:05:03
9	74	2006-02-15 05:05:03
9	147	2006-02-15 05:05:03
9	148	2006-02-15 05:05:03
9	191	2006-02-15 05:05:03
9	200	2006-02-15 05:05:03
9	204	2006-02-15 05:05:03
9	434	2006-02-15 05:05:03
9	510	2006-02-15 05:05:03
9	514	2006-02-15 05:05:03
9	552	2006-02-15 05:05:03
9	650	2006-02-15 05:05:03
9	671	2006-02-15 05:05:03
9	697	2006-02-15 05:05:03
9	722	2006-02-15 05:05:03
9	752	2006-02-15 05:05:03
9	811	2006-02-15 05:05:03
9	815	2006-02-15 05:05:03
9	865	2006-02-15 05:05:03
9	873	2006-02-15 05:05:03
9	889	2006-02-15 05:05:03
9	903	2006-02-15 05:05:03
9	926	2006-02-15 05:05:03
9	964	2006-02-15 05:05:03
9	974	2006-02-15 05:05:03
10	1	2006-02-15 05:05:03
10	9	2006-02-15 05:05:03
10	191	2006-02-15 05:05:03
10	236	2006-02-15 05:05:03
10	251	2006-02-15 05:05:03
10	366	2006-02-15 05:05:03
10	477	2006-02-15 05:05:03
10	480	2006-02-15 05:05:03
10	522	2006-02-15 05:05:03
10	530	2006-02-15 05:05:03
10	587	2006-02-15 05:05:03
10	694	2006-02-15 05:05:03
10	703	2006-02-15 05:05:03
10	716	2006-02-15 05:05:03
10	782	2006-02-15 05:05:03
10	914	2006-02-15 05:05:03
10	929	2006-02-15 05:05:03
10	930	2006-02-15 05:05:03
10	964	2006-02-15 05:05:03
10	966	2006-02-15 05:05:03
10	980	2006-02-15 05:05:03
10	983	2006-02-15 05:05:03
11	118	2006-02-15 05:05:03
11	205	2006-02-15 05:05:03
11	281	2006-02-15 05:05:03
11	283	2006-02-15 05:05:03
11	348	2006-02-15 05:05:03
11	364	2006-02-15 05:05:03
11	395	2006-02-15 05:05:03
11	429	2006-02-15 05:05:03
11	433	2006-02-15 05:05:03
11	453	2006-02-15 05:05:03
11	485	2006-02-15 05:05:03
11	532	2006-02-15 05:05:03
11	567	2006-02-15 05:05:03
11	587	2006-02-15 05:05:03
11	597	2006-02-15 05:05:03
11	636	2006-02-15 05:05:03
11	709	2006-02-15 05:05:03
11	850	2006-02-15 05:05:03
11	854	2006-02-15 05:05:03
11	888	2006-02-15 05:05:03
11	896	2006-02-15 05:05:03
11	928	2006-02-15 05:05:03
11	938	2006-02-15 05:05:03
11	969	2006-02-15 05:05:03
11	988	2006-02-15 05:05:03
12	16	2006-02-15 05:05:03
12	17	2006-02-15 05:05:03
12	34	2006-02-15 05:05:03
12	37	2006-02-15 05:05:03
12	91	2006-02-15 05:05:03
12	92	2006-02-15 05:05:03
12	107	2006-02-15 05:05:03
12	155	2006-02-15 05:05:03
12	177	2006-02-15 05:05:03
12	208	2006-02-15 05:05:03
12	213	2006-02-15 05:05:03
12	216	2006-02-15 05:05:03
12	243	2006-02-15 05:05:03
12	344	2006-02-15 05:05:03
12	400	2006-02-15 05:05:03
12	416	2006-02-15 05:05:03
12	420	2006-02-15 05:05:03
12	457	2006-02-15 05:05:03
12	513	2006-02-15 05:05:03
12	540	2006-02-15 05:05:03
12	593	2006-02-15 05:05:03
12	631	2006-02-15 05:05:03
12	635	2006-02-15 05:05:03
12	672	2006-02-15 05:05:03
12	716	2006-02-15 05:05:03
12	728	2006-02-15 05:05:03
12	812	2006-02-15 05:05:03
12	838	2006-02-15 05:05:03
12	871	2006-02-15 05:05:03
12	880	2006-02-15 05:05:03
12	945	2006-02-15 05:05:03
13	17	2006-02-15 05:05:03
13	29	2006-02-15 05:05:03
13	45	2006-02-15 05:05:03
13	87	2006-02-15 05:05:03
13	110	2006-02-15 05:05:03
13	144	2006-02-15 05:05:03
13	154	2006-02-15 05:05:03
13	162	2006-02-15 05:05:03
13	203	2006-02-15 05:05:03
13	254	2006-02-15 05:05:03
13	337	2006-02-15 05:05:03
13	346	2006-02-15 05:05:03
13	381	2006-02-15 05:05:03
13	385	2006-02-15 05:05:03
13	427	2006-02-15 05:05:03
13	456	2006-02-15 05:05:03
13	513	2006-02-15 05:05:03
13	515	2006-02-15 05:05:03
13	522	2006-02-15 05:05:03
13	524	2006-02-15 05:05:03
13	528	2006-02-15 05:05:03
13	571	2006-02-15 05:05:03
13	588	2006-02-15 05:05:03
13	597	2006-02-15 05:05:03
13	600	2006-02-15 05:05:03
13	718	2006-02-15 05:05:03
13	729	2006-02-15 05:05:03
13	816	2006-02-15 05:05:03
13	817	2006-02-15 05:05:03
13	832	2006-02-15 05:05:03
13	833	2006-02-15 05:05:03
13	843	2006-02-15 05:05:03
13	897	2006-02-15 05:05:03
13	966	2006-02-15 05:05:03
13	998	2006-02-15 05:05:03
14	154	2006-02-15 05:05:03
14	187	2006-02-15 05:05:03
14	232	2006-02-15 05:05:03
14	241	2006-02-15 05:05:03
14	253	2006-02-15 05:05:03
14	255	2006-02-15 05:05:03
14	258	2006-02-15 05:05:03
14	284	2006-02-15 05:05:03
14	292	2006-02-15 05:05:03
14	370	2006-02-15 05:05:03
14	415	2006-02-15 05:05:03
14	417	2006-02-15 05:05:03
14	418	2006-02-15 05:05:03
14	454	2006-02-15 05:05:03
14	472	2006-02-15 05:05:03
14	475	2006-02-15 05:05:03
14	495	2006-02-15 05:05:03
14	536	2006-02-15 05:05:03
14	537	2006-02-15 05:05:03
14	612	2006-02-15 05:05:03
14	688	2006-02-15 05:05:03
14	759	2006-02-15 05:05:03
14	764	2006-02-15 05:05:03
14	847	2006-02-15 05:05:03
14	856	2006-02-15 05:05:03
14	890	2006-02-15 05:05:03
14	908	2006-02-15 05:05:03
14	919	2006-02-15 05:05:03
14	948	2006-02-15 05:05:03
14	970	2006-02-15 05:05:03
15	31	2006-02-15 05:05:03
15	89	2006-02-15 05:05:03
15	91	2006-02-15 05:05:03
15	108	2006-02-15 05:05:03
15	125	2006-02-15 05:05:03
15	236	2006-02-15 05:05:03
15	275	2006-02-15 05:05:03
15	280	2006-02-15 05:05:03
15	326	2006-02-15 05:05:03
15	342	2006-02-15 05:05:03
15	414	2006-02-15 05:05:03
15	445	2006-02-15 05:05:03
15	500	2006-02-15 05:05:03
15	502	2006-02-15 05:05:03
15	541	2006-02-15 05:05:03
15	553	2006-02-15 05:05:03
15	594	2006-02-15 05:05:03
15	626	2006-02-15 05:05:03
15	635	2006-02-15 05:05:03
15	745	2006-02-15 05:05:03
15	783	2006-02-15 05:05:03
15	795	2006-02-15 05:05:03
15	817	2006-02-15 05:05:03
15	886	2006-02-15 05:05:03
15	924	2006-02-15 05:05:03
15	949	2006-02-15 05:05:03
15	968	2006-02-15 05:05:03
15	985	2006-02-15 05:05:03
16	80	2006-02-15 05:05:03
16	87	2006-02-15 05:05:03
16	101	2006-02-15 05:05:03
16	121	2006-02-15 05:05:03
16	155	2006-02-15 05:05:03
16	177	2006-02-15 05:05:03
16	218	2006-02-15 05:05:03
16	221	2006-02-15 05:05:03
16	267	2006-02-15 05:05:03
16	269	2006-02-15 05:05:03
16	271	2006-02-15 05:05:03
16	280	2006-02-15 05:05:03
16	287	2006-02-15 05:05:03
16	345	2006-02-15 05:05:03
16	438	2006-02-15 05:05:03
16	453	2006-02-15 05:05:03
16	455	2006-02-15 05:05:03
16	456	2006-02-15 05:05:03
16	503	2006-02-15 05:05:03
16	548	2006-02-15 05:05:03
16	582	2006-02-15 05:05:03
16	583	2006-02-15 05:05:03
16	717	2006-02-15 05:05:03
16	758	2006-02-15 05:05:03
16	779	2006-02-15 05:05:03
16	886	2006-02-15 05:05:03
16	967	2006-02-15 05:05:03
17	96	2006-02-15 05:05:03
17	119	2006-02-15 05:05:03
17	124	2006-02-15 05:05:03
17	127	2006-02-15 05:05:03
17	154	2006-02-15 05:05:03
17	199	2006-02-15 05:05:03
17	201	2006-02-15 05:05:03
17	236	2006-02-15 05:05:03
17	280	2006-02-15 05:05:03
17	310	2006-02-15 05:05:03
17	313	2006-02-15 05:05:03
17	378	2006-02-15 05:05:03
17	457	2006-02-15 05:05:03
17	469	2006-02-15 05:05:03
17	478	2006-02-15 05:05:03
17	500	2006-02-15 05:05:03
17	515	2006-02-15 05:05:03
17	521	2006-02-15 05:05:03
17	573	2006-02-15 05:05:03
17	603	2006-02-15 05:05:03
17	606	2006-02-15 05:05:03
17	734	2006-02-15 05:05:03
17	770	2006-02-15 05:05:03
17	794	2006-02-15 05:05:03
17	800	2006-02-15 05:05:03
17	853	2006-02-15 05:05:03
17	873	2006-02-15 05:05:03
17	874	2006-02-15 05:05:03
17	880	2006-02-15 05:05:03
17	948	2006-02-15 05:05:03
17	957	2006-02-15 05:05:03
17	959	2006-02-15 05:05:03
18	44	2006-02-15 05:05:03
18	84	2006-02-15 05:05:03
18	144	2006-02-15 05:05:03
18	172	2006-02-15 05:05:03
18	268	2006-02-15 05:05:03
18	279	2006-02-15 05:05:03
18	280	2006-02-15 05:05:03
18	321	2006-02-15 05:05:03
18	386	2006-02-15 05:05:03
18	460	2006-02-15 05:05:03
18	462	2006-02-15 05:05:03
18	484	2006-02-15 05:05:03
18	536	2006-02-15 05:05:03
18	561	2006-02-15 05:05:03
18	612	2006-02-15 05:05:03
18	717	2006-02-15 05:05:03
18	808	2006-02-15 05:05:03
18	842	2006-02-15 05:05:03
18	863	2006-02-15 05:05:03
18	883	2006-02-15 05:05:03
18	917	2006-02-15 05:05:03
18	944	2006-02-15 05:05:03
19	2	2006-02-15 05:05:03
19	3	2006-02-15 05:05:03
19	144	2006-02-15 05:05:03
19	152	2006-02-15 05:05:03
19	182	2006-02-15 05:05:03
19	208	2006-02-15 05:05:03
19	212	2006-02-15 05:05:03
19	217	2006-02-15 05:05:03
19	266	2006-02-15 05:05:03
19	404	2006-02-15 05:05:03
19	428	2006-02-15 05:05:03
19	473	2006-02-15 05:05:03
19	490	2006-02-15 05:05:03
19	510	2006-02-15 05:05:03
19	513	2006-02-15 05:05:03
19	644	2006-02-15 05:05:03
19	670	2006-02-15 05:05:03
19	673	2006-02-15 05:05:03
19	711	2006-02-15 05:05:03
19	750	2006-02-15 05:05:03
19	752	2006-02-15 05:05:03
19	756	2006-02-15 05:05:03
19	771	2006-02-15 05:05:03
19	785	2006-02-15 05:05:03
19	877	2006-02-15 05:05:03
20	1	2006-02-15 05:05:03
20	54	2006-02-15 05:05:03
20	63	2006-02-15 05:05:03
20	140	2006-02-15 05:05:03
20	146	2006-02-15 05:05:03
20	165	2006-02-15 05:05:03
20	231	2006-02-15 05:05:03
20	243	2006-02-15 05:05:03
20	269	2006-02-15 05:05:03
20	274	2006-02-15 05:05:03
20	348	2006-02-15 05:05:03
20	366	2006-02-15 05:05:03
20	445	2006-02-15 05:05:03
20	478	2006-02-15 05:05:03
20	492	2006-02-15 05:05:03
20	499	2006-02-15 05:05:03
20	527	2006-02-15 05:05:03
20	531	2006-02-15 05:05:03
20	538	2006-02-15 05:05:03
20	589	2006-02-15 05:05:03
20	643	2006-02-15 05:05:03
20	652	2006-02-15 05:05:03
20	663	2006-02-15 05:05:03
20	714	2006-02-15 05:05:03
20	717	2006-02-15 05:05:03
20	757	2006-02-15 05:05:03
20	784	2006-02-15 05:05:03
20	863	2006-02-15 05:05:03
20	962	2006-02-15 05:05:03
20	977	2006-02-15 05:05:03
21	6	2006-02-15 05:05:03
21	87	2006-02-15 05:05:03
21	88	2006-02-15 05:05:03
21	142	2006-02-15 05:05:03
21	159	2006-02-15 05:05:03
21	179	2006-02-15 05:05:03
21	253	2006-02-15 05:05:03
21	281	2006-02-15 05:05:03
21	321	2006-02-15 05:05:03
21	398	2006-02-15 05:05:03
21	426	2006-02-15 05:05:03
21	429	2006-02-15 05:05:03
21	497	2006-02-15 05:05:03
21	507	2006-02-15 05:05:03
21	530	2006-02-15 05:05:03
21	680	2006-02-15 05:05:03
21	686	2006-02-15 05:05:03
21	700	2006-02-15 05:05:03
21	702	2006-02-15 05:05:03
21	733	2006-02-15 05:05:03
21	734	2006-02-15 05:05:03
21	798	2006-02-15 05:05:03
21	804	2006-02-15 05:05:03
21	887	2006-02-15 05:05:03
21	893	2006-02-15 05:05:03
21	920	2006-02-15 05:05:03
21	983	2006-02-15 05:05:03
22	9	2006-02-15 05:05:03
22	23	2006-02-15 05:05:03
22	56	2006-02-15 05:05:03
22	89	2006-02-15 05:05:03
22	111	2006-02-15 05:05:03
22	146	2006-02-15 05:05:03
22	291	2006-02-15 05:05:03
22	294	2006-02-15 05:05:03
22	349	2006-02-15 05:05:03
22	369	2006-02-15 05:05:03
22	418	2006-02-15 05:05:03
22	430	2006-02-15 05:05:03
22	483	2006-02-15 05:05:03
22	491	2006-02-15 05:05:03
22	495	2006-02-15 05:05:03
22	536	2006-02-15 05:05:03
22	600	2006-02-15 05:05:03
22	634	2006-02-15 05:05:03
22	648	2006-02-15 05:05:03
22	688	2006-02-15 05:05:03
22	731	2006-02-15 05:05:03
22	742	2006-02-15 05:05:03
22	775	2006-02-15 05:05:03
22	802	2006-02-15 05:05:03
22	912	2006-02-15 05:05:03
22	964	2006-02-15 05:05:03
23	6	2006-02-15 05:05:03
23	42	2006-02-15 05:05:03
23	78	2006-02-15 05:05:03
23	105	2006-02-15 05:05:03
23	116	2006-02-15 05:05:03
23	117	2006-02-15 05:05:03
23	125	2006-02-15 05:05:03
23	212	2006-02-15 05:05:03
23	226	2006-02-15 05:05:03
23	235	2006-02-15 05:05:03
23	254	2006-02-15 05:05:03
23	367	2006-02-15 05:05:03
23	370	2006-02-15 05:05:03
23	414	2006-02-15 05:05:03
23	419	2006-02-15 05:05:03
23	435	2006-02-15 05:05:03
23	449	2006-02-15 05:05:03
23	491	2006-02-15 05:05:03
23	536	2006-02-15 05:05:03
23	549	2006-02-15 05:05:03
23	636	2006-02-15 05:05:03
23	649	2006-02-15 05:05:03
23	673	2006-02-15 05:05:03
23	691	2006-02-15 05:05:03
23	766	2006-02-15 05:05:03
23	782	2006-02-15 05:05:03
23	804	2006-02-15 05:05:03
23	820	2006-02-15 05:05:03
23	826	2006-02-15 05:05:03
23	833	2006-02-15 05:05:03
23	842	2006-02-15 05:05:03
23	853	2006-02-15 05:05:03
23	855	2006-02-15 05:05:03
23	856	2006-02-15 05:05:03
23	935	2006-02-15 05:05:03
23	981	2006-02-15 05:05:03
23	997	2006-02-15 05:05:03
24	3	2006-02-15 05:05:03
24	83	2006-02-15 05:05:03
24	112	2006-02-15 05:05:03
24	126	2006-02-15 05:05:03
24	148	2006-02-15 05:05:03
24	164	2006-02-15 05:05:03
24	178	2006-02-15 05:05:03
24	194	2006-02-15 05:05:03
24	199	2006-02-15 05:05:03
24	242	2006-02-15 05:05:03
24	256	2006-02-15 05:05:03
24	277	2006-02-15 05:05:03
24	335	2006-02-15 05:05:03
24	405	2006-02-15 05:05:03
24	463	2006-02-15 05:05:03
24	515	2006-02-15 05:05:03
24	585	2006-02-15 05:05:03
24	603	2006-02-15 05:05:03
24	653	2006-02-15 05:05:03
24	704	2006-02-15 05:05:03
24	781	2006-02-15 05:05:03
24	829	2006-02-15 05:05:03
24	832	2006-02-15 05:05:03
24	969	2006-02-15 05:05:03
25	21	2006-02-15 05:05:03
25	86	2006-02-15 05:05:03
25	153	2006-02-15 05:05:03
25	179	2006-02-15 05:05:03
25	204	2006-02-15 05:05:03
25	213	2006-02-15 05:05:03
25	226	2006-02-15 05:05:03
25	245	2006-02-15 05:05:03
25	311	2006-02-15 05:05:03
25	404	2006-02-15 05:05:03
25	411	2006-02-15 05:05:03
25	420	2006-02-15 05:05:03
25	538	2006-02-15 05:05:03
25	564	2006-02-15 05:05:03
25	583	2006-02-15 05:05:03
25	606	2006-02-15 05:05:03
25	688	2006-02-15 05:05:03
25	697	2006-02-15 05:05:03
25	755	2006-02-15 05:05:03
25	871	2006-02-15 05:05:03
25	914	2006-02-15 05:05:03
26	9	2006-02-15 05:05:03
26	21	2006-02-15 05:05:03
26	34	2006-02-15 05:05:03
26	90	2006-02-15 05:05:03
26	93	2006-02-15 05:05:03
26	103	2006-02-15 05:05:03
26	147	2006-02-15 05:05:03
26	186	2006-02-15 05:05:03
26	201	2006-02-15 05:05:03
26	225	2006-02-15 05:05:03
26	241	2006-02-15 05:05:03
26	327	2006-02-15 05:05:03
26	329	2006-02-15 05:05:03
26	340	2006-02-15 05:05:03
26	345	2006-02-15 05:05:03
26	390	2006-02-15 05:05:03
26	392	2006-02-15 05:05:03
26	529	2006-02-15 05:05:03
26	544	2006-02-15 05:05:03
26	564	2006-02-15 05:05:03
26	635	2006-02-15 05:05:03
26	644	2006-02-15 05:05:03
26	682	2006-02-15 05:05:03
26	688	2006-02-15 05:05:03
26	715	2006-02-15 05:05:03
26	732	2006-02-15 05:05:03
26	758	2006-02-15 05:05:03
26	764	2006-02-15 05:05:03
26	795	2006-02-15 05:05:03
26	821	2006-02-15 05:05:03
26	885	2006-02-15 05:05:03
26	904	2006-02-15 05:05:03
26	906	2006-02-15 05:05:03
27	19	2006-02-15 05:05:03
27	34	2006-02-15 05:05:03
27	85	2006-02-15 05:05:03
27	150	2006-02-15 05:05:03
27	172	2006-02-15 05:05:03
27	273	2006-02-15 05:05:03
27	334	2006-02-15 05:05:03
27	347	2006-02-15 05:05:03
27	359	2006-02-15 05:05:03
27	398	2006-02-15 05:05:03
27	415	2006-02-15 05:05:03
27	462	2006-02-15 05:05:03
27	477	2006-02-15 05:05:03
27	500	2006-02-15 05:05:03
27	503	2006-02-15 05:05:03
27	540	2006-02-15 05:05:03
27	586	2006-02-15 05:05:03
27	593	2006-02-15 05:05:03
27	637	2006-02-15 05:05:03
27	679	2006-02-15 05:05:03
27	682	2006-02-15 05:05:03
27	695	2006-02-15 05:05:03
27	771	2006-02-15 05:05:03
27	805	2006-02-15 05:05:03
27	830	2006-02-15 05:05:03
27	854	2006-02-15 05:05:03
27	873	2006-02-15 05:05:03
27	880	2006-02-15 05:05:03
27	889	2006-02-15 05:05:03
27	904	2006-02-15 05:05:03
27	967	2006-02-15 05:05:03
27	986	2006-02-15 05:05:03
27	996	2006-02-15 05:05:03
28	14	2006-02-15 05:05:03
28	43	2006-02-15 05:05:03
28	58	2006-02-15 05:05:03
28	74	2006-02-15 05:05:03
28	96	2006-02-15 05:05:03
28	107	2006-02-15 05:05:03
28	259	2006-02-15 05:05:03
28	263	2006-02-15 05:05:03
28	287	2006-02-15 05:05:03
28	358	2006-02-15 05:05:03
28	502	2006-02-15 05:05:03
28	508	2006-02-15 05:05:03
28	532	2006-02-15 05:05:03
28	551	2006-02-15 05:05:03
28	574	2006-02-15 05:05:03
28	597	2006-02-15 05:05:03
28	619	2006-02-15 05:05:03
28	625	2006-02-15 05:05:03
28	652	2006-02-15 05:05:03
28	679	2006-02-15 05:05:03
28	743	2006-02-15 05:05:03
28	790	2006-02-15 05:05:03
28	793	2006-02-15 05:05:03
28	816	2006-02-15 05:05:03
28	827	2006-02-15 05:05:03
28	835	2006-02-15 05:05:03
28	879	2006-02-15 05:05:03
28	908	2006-02-15 05:05:03
28	953	2006-02-15 05:05:03
28	973	2006-02-15 05:05:03
28	994	2006-02-15 05:05:03
29	10	2006-02-15 05:05:03
29	79	2006-02-15 05:05:03
29	105	2006-02-15 05:05:03
29	110	2006-02-15 05:05:03
29	131	2006-02-15 05:05:03
29	133	2006-02-15 05:05:03
29	172	2006-02-15 05:05:03
29	226	2006-02-15 05:05:03
29	273	2006-02-15 05:05:03
29	282	2006-02-15 05:05:03
29	296	2006-02-15 05:05:03
29	311	2006-02-15 05:05:03
29	335	2006-02-15 05:05:03
29	342	2006-02-15 05:05:03
29	436	2006-02-15 05:05:03
29	444	2006-02-15 05:05:03
29	449	2006-02-15 05:05:03
29	462	2006-02-15 05:05:03
29	482	2006-02-15 05:05:03
29	488	2006-02-15 05:05:03
29	519	2006-02-15 05:05:03
29	547	2006-02-15 05:05:03
29	590	2006-02-15 05:05:03
29	646	2006-02-15 05:05:03
29	723	2006-02-15 05:05:03
29	812	2006-02-15 05:05:03
29	862	2006-02-15 05:05:03
29	928	2006-02-15 05:05:03
29	944	2006-02-15 05:05:03
30	1	2006-02-15 05:05:03
30	53	2006-02-15 05:05:03
30	64	2006-02-15 05:05:03
30	69	2006-02-15 05:05:03
30	77	2006-02-15 05:05:03
30	87	2006-02-15 05:05:03
30	260	2006-02-15 05:05:03
30	262	2006-02-15 05:05:03
30	286	2006-02-15 05:05:03
30	292	2006-02-15 05:05:03
30	301	2006-02-15 05:05:03
30	318	2006-02-15 05:05:03
30	321	2006-02-15 05:05:03
30	357	2006-02-15 05:05:03
30	565	2006-02-15 05:05:03
30	732	2006-02-15 05:05:03
30	797	2006-02-15 05:05:03
30	838	2006-02-15 05:05:03
30	945	2006-02-15 05:05:03
31	88	2006-02-15 05:05:03
31	146	2006-02-15 05:05:03
31	163	2006-02-15 05:05:03
31	164	2006-02-15 05:05:03
31	188	2006-02-15 05:05:03
31	299	2006-02-15 05:05:03
31	308	2006-02-15 05:05:03
31	368	2006-02-15 05:05:03
31	380	2006-02-15 05:05:03
31	431	2006-02-15 05:05:03
31	585	2006-02-15 05:05:03
31	637	2006-02-15 05:05:03
31	700	2006-02-15 05:05:03
31	739	2006-02-15 05:05:03
31	793	2006-02-15 05:05:03
31	802	2006-02-15 05:05:03
31	880	2006-02-15 05:05:03
31	978	2006-02-15 05:05:03
32	65	2006-02-15 05:05:03
32	84	2006-02-15 05:05:03
32	103	2006-02-15 05:05:03
32	112	2006-02-15 05:05:03
32	136	2006-02-15 05:05:03
32	197	2006-02-15 05:05:03
32	199	2006-02-15 05:05:03
32	219	2006-02-15 05:05:03
32	309	2006-02-15 05:05:03
32	312	2006-02-15 05:05:03
32	401	2006-02-15 05:05:03
32	427	2006-02-15 05:05:03
32	431	2006-02-15 05:05:03
32	523	2006-02-15 05:05:03
32	567	2006-02-15 05:05:03
32	585	2006-02-15 05:05:03
32	606	2006-02-15 05:05:03
32	651	2006-02-15 05:05:03
32	667	2006-02-15 05:05:03
32	669	2006-02-15 05:05:03
32	815	2006-02-15 05:05:03
32	928	2006-02-15 05:05:03
32	980	2006-02-15 05:05:03
33	56	2006-02-15 05:05:03
33	112	2006-02-15 05:05:03
33	135	2006-02-15 05:05:03
33	154	2006-02-15 05:05:03
33	214	2006-02-15 05:05:03
33	252	2006-02-15 05:05:03
33	305	2006-02-15 05:05:03
33	306	2006-02-15 05:05:03
33	473	2006-02-15 05:05:03
33	489	2006-02-15 05:05:03
33	574	2006-02-15 05:05:03
33	618	2006-02-15 05:05:03
33	667	2006-02-15 05:05:03
33	694	2006-02-15 05:05:03
33	712	2006-02-15 05:05:03
33	735	2006-02-15 05:05:03
33	737	2006-02-15 05:05:03
33	754	2006-02-15 05:05:03
33	775	2006-02-15 05:05:03
33	878	2006-02-15 05:05:03
33	881	2006-02-15 05:05:03
33	965	2006-02-15 05:05:03
33	972	2006-02-15 05:05:03
33	993	2006-02-15 05:05:03
34	43	2006-02-15 05:05:03
34	90	2006-02-15 05:05:03
34	119	2006-02-15 05:05:03
34	125	2006-02-15 05:05:03
34	172	2006-02-15 05:05:03
34	182	2006-02-15 05:05:03
34	244	2006-02-15 05:05:03
34	336	2006-02-15 05:05:03
34	389	2006-02-15 05:05:03
34	393	2006-02-15 05:05:03
34	438	2006-02-15 05:05:03
34	493	2006-02-15 05:05:03
34	502	2006-02-15 05:05:03
34	525	2006-02-15 05:05:03
34	668	2006-02-15 05:05:03
34	720	2006-02-15 05:05:03
34	779	2006-02-15 05:05:03
34	788	2006-02-15 05:05:03
34	794	2006-02-15 05:05:03
34	836	2006-02-15 05:05:03
34	846	2006-02-15 05:05:03
34	853	2006-02-15 05:05:03
34	929	2006-02-15 05:05:03
34	950	2006-02-15 05:05:03
34	971	2006-02-15 05:05:03
35	10	2006-02-15 05:05:03
35	35	2006-02-15 05:05:03
35	52	2006-02-15 05:05:03
35	201	2006-02-15 05:05:03
35	256	2006-02-15 05:05:03
35	389	2006-02-15 05:05:03
35	589	2006-02-15 05:05:03
35	612	2006-02-15 05:05:03
35	615	2006-02-15 05:05:03
35	707	2006-02-15 05:05:03
35	732	2006-02-15 05:05:03
35	738	2006-02-15 05:05:03
35	748	2006-02-15 05:05:03
35	817	2006-02-15 05:05:03
35	914	2006-02-15 05:05:03
36	15	2006-02-15 05:05:03
36	81	2006-02-15 05:05:03
36	171	2006-02-15 05:05:03
36	231	2006-02-15 05:05:03
36	245	2006-02-15 05:05:03
36	283	2006-02-15 05:05:03
36	380	2006-02-15 05:05:03
36	381	2006-02-15 05:05:03
36	387	2006-02-15 05:05:03
36	390	2006-02-15 05:05:03
36	410	2006-02-15 05:05:03
36	426	2006-02-15 05:05:03
36	427	2006-02-15 05:05:03
36	453	2006-02-15 05:05:03
36	466	2006-02-15 05:05:03
36	484	2006-02-15 05:05:03
36	493	2006-02-15 05:05:03
36	499	2006-02-15 05:05:03
36	569	2006-02-15 05:05:03
36	590	2006-02-15 05:05:03
36	600	2006-02-15 05:05:03
36	714	2006-02-15 05:05:03
36	715	2006-02-15 05:05:03
36	716	2006-02-15 05:05:03
36	731	2006-02-15 05:05:03
36	875	2006-02-15 05:05:03
36	915	2006-02-15 05:05:03
36	931	2006-02-15 05:05:03
36	956	2006-02-15 05:05:03
37	10	2006-02-15 05:05:03
37	12	2006-02-15 05:05:03
37	19	2006-02-15 05:05:03
37	118	2006-02-15 05:05:03
37	119	2006-02-15 05:05:03
37	122	2006-02-15 05:05:03
37	146	2006-02-15 05:05:03
37	204	2006-02-15 05:05:03
37	253	2006-02-15 05:05:03
37	260	2006-02-15 05:05:03
37	277	2006-02-15 05:05:03
37	317	2006-02-15 05:05:03
37	467	2006-02-15 05:05:03
37	477	2006-02-15 05:05:03
37	485	2006-02-15 05:05:03
37	508	2006-02-15 05:05:03
37	529	2006-02-15 05:05:03
37	553	2006-02-15 05:05:03
37	555	2006-02-15 05:05:03
37	572	2006-02-15 05:05:03
37	588	2006-02-15 05:05:03
37	662	2006-02-15 05:05:03
37	663	2006-02-15 05:05:03
37	694	2006-02-15 05:05:03
37	697	2006-02-15 05:05:03
37	785	2006-02-15 05:05:03
37	839	2006-02-15 05:05:03
37	840	2006-02-15 05:05:03
37	853	2006-02-15 05:05:03
37	900	2006-02-15 05:05:03
37	925	2006-02-15 05:05:03
37	963	2006-02-15 05:05:03
37	966	2006-02-15 05:05:03
37	989	2006-02-15 05:05:03
37	997	2006-02-15 05:05:03
38	24	2006-02-15 05:05:03
38	111	2006-02-15 05:05:03
38	160	2006-02-15 05:05:03
38	176	2006-02-15 05:05:03
38	223	2006-02-15 05:05:03
38	241	2006-02-15 05:05:03
38	274	2006-02-15 05:05:03
38	335	2006-02-15 05:05:03
38	338	2006-02-15 05:05:03
38	353	2006-02-15 05:05:03
38	448	2006-02-15 05:05:03
38	450	2006-02-15 05:05:03
38	458	2006-02-15 05:05:03
38	501	2006-02-15 05:05:03
38	516	2006-02-15 05:05:03
38	547	2006-02-15 05:05:03
38	583	2006-02-15 05:05:03
38	618	2006-02-15 05:05:03
38	619	2006-02-15 05:05:03
38	705	2006-02-15 05:05:03
38	793	2006-02-15 05:05:03
38	827	2006-02-15 05:05:03
38	839	2006-02-15 05:05:03
38	853	2006-02-15 05:05:03
38	876	2006-02-15 05:05:03
39	71	2006-02-15 05:05:03
39	73	2006-02-15 05:05:03
39	168	2006-02-15 05:05:03
39	203	2006-02-15 05:05:03
39	222	2006-02-15 05:05:03
39	290	2006-02-15 05:05:03
39	293	2006-02-15 05:05:03
39	320	2006-02-15 05:05:03
39	415	2006-02-15 05:05:03
39	425	2006-02-15 05:05:03
39	431	2006-02-15 05:05:03
39	456	2006-02-15 05:05:03
39	476	2006-02-15 05:05:03
39	559	2006-02-15 05:05:03
39	587	2006-02-15 05:05:03
39	598	2006-02-15 05:05:03
39	606	2006-02-15 05:05:03
39	648	2006-02-15 05:05:03
39	683	2006-02-15 05:05:03
39	689	2006-02-15 05:05:03
39	696	2006-02-15 05:05:03
39	700	2006-02-15 05:05:03
39	703	2006-02-15 05:05:03
39	736	2006-02-15 05:05:03
39	772	2006-02-15 05:05:03
39	815	2006-02-15 05:05:03
39	831	2006-02-15 05:05:03
39	920	2006-02-15 05:05:03
40	1	2006-02-15 05:05:03
40	11	2006-02-15 05:05:03
40	34	2006-02-15 05:05:03
40	107	2006-02-15 05:05:03
40	128	2006-02-15 05:05:03
40	163	2006-02-15 05:05:03
40	177	2006-02-15 05:05:03
40	223	2006-02-15 05:05:03
40	233	2006-02-15 05:05:03
40	326	2006-02-15 05:05:03
40	374	2006-02-15 05:05:03
40	394	2006-02-15 05:05:03
40	396	2006-02-15 05:05:03
40	463	2006-02-15 05:05:03
40	466	2006-02-15 05:05:03
40	494	2006-02-15 05:05:03
40	521	2006-02-15 05:05:03
40	723	2006-02-15 05:05:03
40	737	2006-02-15 05:05:03
40	744	2006-02-15 05:05:03
40	747	2006-02-15 05:05:03
40	754	2006-02-15 05:05:03
40	799	2006-02-15 05:05:03
40	835	2006-02-15 05:05:03
40	868	2006-02-15 05:05:03
40	869	2006-02-15 05:05:03
40	887	2006-02-15 05:05:03
40	933	2006-02-15 05:05:03
40	938	2006-02-15 05:05:03
41	4	2006-02-15 05:05:03
41	60	2006-02-15 05:05:03
41	69	2006-02-15 05:05:03
41	86	2006-02-15 05:05:03
41	100	2006-02-15 05:05:03
41	150	2006-02-15 05:05:03
41	159	2006-02-15 05:05:03
41	194	2006-02-15 05:05:03
41	203	2006-02-15 05:05:03
41	212	2006-02-15 05:05:03
41	230	2006-02-15 05:05:03
41	249	2006-02-15 05:05:03
41	252	2006-02-15 05:05:03
41	305	2006-02-15 05:05:03
41	336	2006-02-15 05:05:03
41	383	2006-02-15 05:05:03
41	544	2006-02-15 05:05:03
41	596	2006-02-15 05:05:03
41	657	2006-02-15 05:05:03
41	674	2006-02-15 05:05:03
41	678	2006-02-15 05:05:03
41	721	2006-02-15 05:05:03
41	724	2006-02-15 05:05:03
41	779	2006-02-15 05:05:03
41	784	2006-02-15 05:05:03
41	799	2006-02-15 05:05:03
41	894	2006-02-15 05:05:03
41	912	2006-02-15 05:05:03
41	942	2006-02-15 05:05:03
42	24	2006-02-15 05:05:03
42	139	2006-02-15 05:05:03
42	309	2006-02-15 05:05:03
42	320	2006-02-15 05:05:03
42	333	2006-02-15 05:05:03
42	500	2006-02-15 05:05:03
42	502	2006-02-15 05:05:03
42	505	2006-02-15 05:05:03
42	527	2006-02-15 05:05:03
42	535	2006-02-15 05:05:03
42	546	2006-02-15 05:05:03
42	568	2006-02-15 05:05:03
42	648	2006-02-15 05:05:03
42	665	2006-02-15 05:05:03
42	673	2006-02-15 05:05:03
42	687	2006-02-15 05:05:03
42	713	2006-02-15 05:05:03
42	738	2006-02-15 05:05:03
42	798	2006-02-15 05:05:03
42	861	2006-02-15 05:05:03
42	865	2006-02-15 05:05:03
42	867	2006-02-15 05:05:03
42	876	2006-02-15 05:05:03
42	890	2006-02-15 05:05:03
42	907	2006-02-15 05:05:03
42	922	2006-02-15 05:05:03
42	932	2006-02-15 05:05:03
43	19	2006-02-15 05:05:03
43	42	2006-02-15 05:05:03
43	56	2006-02-15 05:05:03
43	89	2006-02-15 05:05:03
43	105	2006-02-15 05:05:03
43	147	2006-02-15 05:05:03
43	161	2006-02-15 05:05:03
43	180	2006-02-15 05:05:03
43	239	2006-02-15 05:05:03
43	276	2006-02-15 05:05:03
43	330	2006-02-15 05:05:03
43	344	2006-02-15 05:05:03
43	359	2006-02-15 05:05:03
43	377	2006-02-15 05:05:03
43	410	2006-02-15 05:05:03
43	462	2006-02-15 05:05:03
43	533	2006-02-15 05:05:03
43	598	2006-02-15 05:05:03
43	605	2006-02-15 05:05:03
43	608	2006-02-15 05:05:03
43	621	2006-02-15 05:05:03
43	753	2006-02-15 05:05:03
43	827	2006-02-15 05:05:03
43	833	2006-02-15 05:05:03
43	917	2006-02-15 05:05:03
43	958	2006-02-15 05:05:03
44	58	2006-02-15 05:05:03
44	84	2006-02-15 05:05:03
44	88	2006-02-15 05:05:03
44	94	2006-02-15 05:05:03
44	109	2006-02-15 05:05:03
44	176	2006-02-15 05:05:03
44	242	2006-02-15 05:05:03
44	273	2006-02-15 05:05:03
44	322	2006-02-15 05:05:03
44	420	2006-02-15 05:05:03
44	434	2006-02-15 05:05:03
44	490	2006-02-15 05:05:03
44	591	2006-02-15 05:05:03
44	598	2006-02-15 05:05:03
44	604	2006-02-15 05:05:03
44	699	2006-02-15 05:05:03
44	751	2006-02-15 05:05:03
44	784	2006-02-15 05:05:03
44	825	2006-02-15 05:05:03
44	854	2006-02-15 05:05:03
44	875	2006-02-15 05:05:03
44	878	2006-02-15 05:05:03
44	883	2006-02-15 05:05:03
44	896	2006-02-15 05:05:03
44	902	2006-02-15 05:05:03
44	937	2006-02-15 05:05:03
44	944	2006-02-15 05:05:03
44	952	2006-02-15 05:05:03
44	982	2006-02-15 05:05:03
44	998	2006-02-15 05:05:03
45	18	2006-02-15 05:05:03
45	65	2006-02-15 05:05:03
45	66	2006-02-15 05:05:03
45	115	2006-02-15 05:05:03
45	117	2006-02-15 05:05:03
45	164	2006-02-15 05:05:03
45	187	2006-02-15 05:05:03
45	198	2006-02-15 05:05:03
45	219	2006-02-15 05:05:03
45	330	2006-02-15 05:05:03
45	407	2006-02-15 05:05:03
45	416	2006-02-15 05:05:03
45	463	2006-02-15 05:05:03
45	467	2006-02-15 05:05:03
45	484	2006-02-15 05:05:03
45	502	2006-02-15 05:05:03
45	503	2006-02-15 05:05:03
45	508	2006-02-15 05:05:03
45	537	2006-02-15 05:05:03
45	680	2006-02-15 05:05:03
45	714	2006-02-15 05:05:03
45	767	2006-02-15 05:05:03
45	778	2006-02-15 05:05:03
45	797	2006-02-15 05:05:03
45	810	2006-02-15 05:05:03
45	895	2006-02-15 05:05:03
45	900	2006-02-15 05:05:03
45	901	2006-02-15 05:05:03
45	920	2006-02-15 05:05:03
45	925	2006-02-15 05:05:03
45	975	2006-02-15 05:05:03
45	978	2006-02-15 05:05:03
46	38	2006-02-15 05:05:03
46	51	2006-02-15 05:05:03
46	174	2006-02-15 05:05:03
46	254	2006-02-15 05:05:03
46	296	2006-02-15 05:05:03
46	319	2006-02-15 05:05:03
46	407	2006-02-15 05:05:03
46	448	2006-02-15 05:05:03
46	456	2006-02-15 05:05:03
46	463	2006-02-15 05:05:03
46	478	2006-02-15 05:05:03
46	538	2006-02-15 05:05:03
46	540	2006-02-15 05:05:03
46	567	2006-02-15 05:05:03
46	731	2006-02-15 05:05:03
46	766	2006-02-15 05:05:03
46	768	2006-02-15 05:05:03
46	820	2006-02-15 05:05:03
46	829	2006-02-15 05:05:03
46	830	2006-02-15 05:05:03
46	836	2006-02-15 05:05:03
46	889	2006-02-15 05:05:03
46	980	2006-02-15 05:05:03
46	991	2006-02-15 05:05:03
47	25	2006-02-15 05:05:03
47	36	2006-02-15 05:05:03
47	53	2006-02-15 05:05:03
47	67	2006-02-15 05:05:03
47	172	2006-02-15 05:05:03
47	233	2006-02-15 05:05:03
47	273	2006-02-15 05:05:03
47	351	2006-02-15 05:05:03
47	385	2006-02-15 05:05:03
47	484	2006-02-15 05:05:03
47	508	2006-02-15 05:05:03
47	576	2006-02-15 05:05:03
47	670	2006-02-15 05:05:03
47	734	2006-02-15 05:05:03
47	737	2006-02-15 05:05:03
47	770	2006-02-15 05:05:03
47	777	2006-02-15 05:05:03
47	787	2006-02-15 05:05:03
47	790	2006-02-15 05:05:03
47	913	2006-02-15 05:05:03
47	923	2006-02-15 05:05:03
47	924	2006-02-15 05:05:03
47	944	2006-02-15 05:05:03
47	973	2006-02-15 05:05:03
48	99	2006-02-15 05:05:03
48	101	2006-02-15 05:05:03
48	134	2006-02-15 05:05:03
48	150	2006-02-15 05:05:03
48	164	2006-02-15 05:05:03
48	211	2006-02-15 05:05:03
48	245	2006-02-15 05:05:03
48	267	2006-02-15 05:05:03
48	287	2006-02-15 05:05:03
48	295	2006-02-15 05:05:03
48	312	2006-02-15 05:05:03
48	315	2006-02-15 05:05:03
48	345	2006-02-15 05:05:03
48	349	2006-02-15 05:05:03
48	428	2006-02-15 05:05:03
48	506	2006-02-15 05:05:03
48	545	2006-02-15 05:05:03
48	559	2006-02-15 05:05:03
48	570	2006-02-15 05:05:03
48	599	2006-02-15 05:05:03
48	645	2006-02-15 05:05:03
48	705	2006-02-15 05:05:03
48	757	2006-02-15 05:05:03
48	792	2006-02-15 05:05:03
48	922	2006-02-15 05:05:03
48	926	2006-02-15 05:05:03
49	31	2006-02-15 05:05:03
49	151	2006-02-15 05:05:03
49	195	2006-02-15 05:05:03
49	207	2006-02-15 05:05:03
49	250	2006-02-15 05:05:03
49	282	2006-02-15 05:05:03
49	348	2006-02-15 05:05:03
49	391	2006-02-15 05:05:03
49	400	2006-02-15 05:05:03
49	407	2006-02-15 05:05:03
49	423	2006-02-15 05:05:03
49	433	2006-02-15 05:05:03
49	469	2006-02-15 05:05:03
49	506	2006-02-15 05:05:03
49	542	2006-02-15 05:05:03
49	558	2006-02-15 05:05:03
49	579	2006-02-15 05:05:03
49	595	2006-02-15 05:05:03
49	662	2006-02-15 05:05:03
49	709	2006-02-15 05:05:03
49	716	2006-02-15 05:05:03
49	725	2006-02-15 05:05:03
49	729	2006-02-15 05:05:03
49	811	2006-02-15 05:05:03
49	927	2006-02-15 05:05:03
49	977	2006-02-15 05:05:03
49	980	2006-02-15 05:05:03
50	111	2006-02-15 05:05:03
50	178	2006-02-15 05:05:03
50	243	2006-02-15 05:05:03
50	248	2006-02-15 05:05:03
50	274	2006-02-15 05:05:03
50	288	2006-02-15 05:05:03
50	303	2006-02-15 05:05:03
50	306	2006-02-15 05:05:03
50	327	2006-02-15 05:05:03
50	372	2006-02-15 05:05:03
50	401	2006-02-15 05:05:03
50	417	2006-02-15 05:05:03
50	420	2006-02-15 05:05:03
50	437	2006-02-15 05:05:03
50	476	2006-02-15 05:05:03
50	504	2006-02-15 05:05:03
50	520	2006-02-15 05:05:03
50	552	2006-02-15 05:05:03
50	591	2006-02-15 05:05:03
50	621	2006-02-15 05:05:03
50	632	2006-02-15 05:05:03
50	645	2006-02-15 05:05:03
50	672	2006-02-15 05:05:03
50	717	2006-02-15 05:05:03
50	732	2006-02-15 05:05:03
50	795	2006-02-15 05:05:03
50	829	2006-02-15 05:05:03
50	840	2006-02-15 05:05:03
50	897	2006-02-15 05:05:03
50	918	2006-02-15 05:05:03
50	924	2006-02-15 05:05:03
50	957	2006-02-15 05:05:03
51	5	2006-02-15 05:05:03
51	63	2006-02-15 05:05:03
51	103	2006-02-15 05:05:03
51	112	2006-02-15 05:05:03
51	121	2006-02-15 05:05:03
51	153	2006-02-15 05:05:03
51	395	2006-02-15 05:05:03
51	408	2006-02-15 05:05:03
51	420	2006-02-15 05:05:03
51	461	2006-02-15 05:05:03
51	490	2006-02-15 05:05:03
51	525	2006-02-15 05:05:03
51	627	2006-02-15 05:05:03
51	678	2006-02-15 05:05:03
51	733	2006-02-15 05:05:03
51	734	2006-02-15 05:05:03
51	737	2006-02-15 05:05:03
51	750	2006-02-15 05:05:03
51	847	2006-02-15 05:05:03
51	891	2006-02-15 05:05:03
51	895	2006-02-15 05:05:03
51	940	2006-02-15 05:05:03
51	974	2006-02-15 05:05:03
51	990	2006-02-15 05:05:03
51	993	2006-02-15 05:05:03
52	20	2006-02-15 05:05:03
52	92	2006-02-15 05:05:03
52	96	2006-02-15 05:05:03
52	108	2006-02-15 05:05:03
52	203	2006-02-15 05:05:03
52	249	2006-02-15 05:05:03
52	341	2006-02-15 05:05:03
52	376	2006-02-15 05:05:03
52	388	2006-02-15 05:05:03
52	407	2006-02-15 05:05:03
52	424	2006-02-15 05:05:03
52	474	2006-02-15 05:05:03
52	515	2006-02-15 05:05:03
52	517	2006-02-15 05:05:03
52	584	2006-02-15 05:05:03
52	596	2006-02-15 05:05:03
52	664	2006-02-15 05:05:03
52	675	2006-02-15 05:05:03
52	689	2006-02-15 05:05:03
52	714	2006-02-15 05:05:03
52	812	2006-02-15 05:05:03
52	878	2006-02-15 05:05:03
52	879	2006-02-15 05:05:03
52	915	2006-02-15 05:05:03
52	951	2006-02-15 05:05:03
52	999	2006-02-15 05:05:03
53	1	2006-02-15 05:05:03
53	9	2006-02-15 05:05:03
53	51	2006-02-15 05:05:03
53	58	2006-02-15 05:05:03
53	109	2006-02-15 05:05:03
53	122	2006-02-15 05:05:03
53	126	2006-02-15 05:05:03
53	181	2006-02-15 05:05:03
53	256	2006-02-15 05:05:03
53	268	2006-02-15 05:05:03
53	285	2006-02-15 05:05:03
53	307	2006-02-15 05:05:03
53	358	2006-02-15 05:05:03
53	386	2006-02-15 05:05:03
53	447	2006-02-15 05:05:03
53	465	2006-02-15 05:05:03
53	490	2006-02-15 05:05:03
53	492	2006-02-15 05:05:03
53	508	2006-02-15 05:05:03
53	518	2006-02-15 05:05:03
53	573	2006-02-15 05:05:03
53	576	2006-02-15 05:05:03
53	577	2006-02-15 05:05:03
53	697	2006-02-15 05:05:03
53	725	2006-02-15 05:05:03
53	727	2006-02-15 05:05:03
53	937	2006-02-15 05:05:03
53	947	2006-02-15 05:05:03
53	961	2006-02-15 05:05:03
53	980	2006-02-15 05:05:03
54	84	2006-02-15 05:05:03
54	129	2006-02-15 05:05:03
54	150	2006-02-15 05:05:03
54	184	2006-02-15 05:05:03
54	285	2006-02-15 05:05:03
54	292	2006-02-15 05:05:03
54	301	2006-02-15 05:05:03
54	348	2006-02-15 05:05:03
54	489	2006-02-15 05:05:03
54	510	2006-02-15 05:05:03
54	524	2006-02-15 05:05:03
54	546	2006-02-15 05:05:03
54	600	2006-02-15 05:05:03
54	636	2006-02-15 05:05:03
54	649	2006-02-15 05:05:03
54	658	2006-02-15 05:05:03
54	754	2006-02-15 05:05:03
54	764	2006-02-15 05:05:03
54	842	2006-02-15 05:05:03
54	858	2006-02-15 05:05:03
54	861	2006-02-15 05:05:03
54	913	2006-02-15 05:05:03
54	970	2006-02-15 05:05:03
54	988	2006-02-15 05:05:03
54	990	2006-02-15 05:05:03
55	8	2006-02-15 05:05:03
55	27	2006-02-15 05:05:03
55	75	2006-02-15 05:05:03
55	197	2006-02-15 05:05:03
55	307	2006-02-15 05:05:03
55	320	2006-02-15 05:05:03
55	340	2006-02-15 05:05:03
55	403	2006-02-15 05:05:03
55	485	2006-02-15 05:05:03
55	486	2006-02-15 05:05:03
55	603	2006-02-15 05:05:03
55	612	2006-02-15 05:05:03
55	620	2006-02-15 05:05:03
55	709	2006-02-15 05:05:03
55	776	2006-02-15 05:05:03
55	790	2006-02-15 05:05:03
55	815	2006-02-15 05:05:03
55	827	2006-02-15 05:05:03
55	930	2006-02-15 05:05:03
55	963	2006-02-15 05:05:03
56	63	2006-02-15 05:05:03
56	87	2006-02-15 05:05:03
56	226	2006-02-15 05:05:03
56	236	2006-02-15 05:05:03
56	298	2006-02-15 05:05:03
56	307	2006-02-15 05:05:03
56	354	2006-02-15 05:05:03
56	383	2006-02-15 05:05:03
56	417	2006-02-15 05:05:03
56	421	2006-02-15 05:05:03
56	457	2006-02-15 05:05:03
56	462	2006-02-15 05:05:03
56	474	2006-02-15 05:05:03
56	521	2006-02-15 05:05:03
56	593	2006-02-15 05:05:03
56	728	2006-02-15 05:05:03
56	750	2006-02-15 05:05:03
56	769	2006-02-15 05:05:03
56	781	2006-02-15 05:05:03
56	795	2006-02-15 05:05:03
56	844	2006-02-15 05:05:03
56	851	2006-02-15 05:05:03
56	862	2006-02-15 05:05:03
56	868	2006-02-15 05:05:03
56	892	2006-02-15 05:05:03
56	893	2006-02-15 05:05:03
56	936	2006-02-15 05:05:03
56	965	2006-02-15 05:05:03
57	16	2006-02-15 05:05:03
57	34	2006-02-15 05:05:03
57	101	2006-02-15 05:05:03
57	114	2006-02-15 05:05:03
57	122	2006-02-15 05:05:03
57	134	2006-02-15 05:05:03
57	144	2006-02-15 05:05:03
57	153	2006-02-15 05:05:03
57	192	2006-02-15 05:05:03
57	213	2006-02-15 05:05:03
57	258	2006-02-15 05:05:03
57	267	2006-02-15 05:05:03
57	317	2006-02-15 05:05:03
57	340	2006-02-15 05:05:03
57	393	2006-02-15 05:05:03
57	437	2006-02-15 05:05:03
57	447	2006-02-15 05:05:03
57	502	2006-02-15 05:05:03
57	592	2006-02-15 05:05:03
57	605	2006-02-15 05:05:03
57	637	2006-02-15 05:05:03
57	685	2006-02-15 05:05:03
57	707	2006-02-15 05:05:03
57	714	2006-02-15 05:05:03
57	717	2006-02-15 05:05:03
57	737	2006-02-15 05:05:03
57	767	2006-02-15 05:05:03
57	852	2006-02-15 05:05:03
57	891	2006-02-15 05:05:03
57	918	2006-02-15 05:05:03
58	48	2006-02-15 05:05:03
58	68	2006-02-15 05:05:03
58	119	2006-02-15 05:05:03
58	128	2006-02-15 05:05:03
58	135	2006-02-15 05:05:03
58	175	2006-02-15 05:05:03
58	199	2006-02-15 05:05:03
58	235	2006-02-15 05:05:03
58	242	2006-02-15 05:05:03
58	243	2006-02-15 05:05:03
58	254	2006-02-15 05:05:03
58	306	2006-02-15 05:05:03
58	316	2006-02-15 05:05:03
58	417	2006-02-15 05:05:03
58	426	2006-02-15 05:05:03
58	460	2006-02-15 05:05:03
58	477	2006-02-15 05:05:03
58	541	2006-02-15 05:05:03
58	549	2006-02-15 05:05:03
58	551	2006-02-15 05:05:03
58	553	2006-02-15 05:05:03
58	578	2006-02-15 05:05:03
58	602	2006-02-15 05:05:03
58	632	2006-02-15 05:05:03
58	635	2006-02-15 05:05:03
58	638	2006-02-15 05:05:03
58	698	2006-02-15 05:05:03
58	726	2006-02-15 05:05:03
58	755	2006-02-15 05:05:03
58	800	2006-02-15 05:05:03
58	856	2006-02-15 05:05:03
58	858	2006-02-15 05:05:03
59	5	2006-02-15 05:05:03
59	46	2006-02-15 05:05:03
59	54	2006-02-15 05:05:03
59	72	2006-02-15 05:05:03
59	88	2006-02-15 05:05:03
59	121	2006-02-15 05:05:03
59	129	2006-02-15 05:05:03
59	130	2006-02-15 05:05:03
59	183	2006-02-15 05:05:03
59	210	2006-02-15 05:05:03
59	241	2006-02-15 05:05:03
59	295	2006-02-15 05:05:03
59	418	2006-02-15 05:05:03
59	572	2006-02-15 05:05:03
59	644	2006-02-15 05:05:03
59	650	2006-02-15 05:05:03
59	689	2006-02-15 05:05:03
59	694	2006-02-15 05:05:03
59	702	2006-02-15 05:05:03
59	713	2006-02-15 05:05:03
59	749	2006-02-15 05:05:03
59	772	2006-02-15 05:05:03
59	853	2006-02-15 05:05:03
59	862	2006-02-15 05:05:03
59	943	2006-02-15 05:05:03
59	946	2006-02-15 05:05:03
59	984	2006-02-15 05:05:03
60	31	2006-02-15 05:05:03
60	85	2006-02-15 05:05:03
60	133	2006-02-15 05:05:03
60	142	2006-02-15 05:05:03
60	177	2006-02-15 05:05:03
60	179	2006-02-15 05:05:03
60	186	2006-02-15 05:05:03
60	222	2006-02-15 05:05:03
60	235	2006-02-15 05:05:03
60	239	2006-02-15 05:05:03
60	253	2006-02-15 05:05:03
60	262	2006-02-15 05:05:03
60	297	2006-02-15 05:05:03
60	299	2006-02-15 05:05:03
60	334	2006-02-15 05:05:03
60	376	2006-02-15 05:05:03
60	423	2006-02-15 05:05:03
60	436	2006-02-15 05:05:03
60	493	2006-02-15 05:05:03
60	534	2006-02-15 05:05:03
60	551	2006-02-15 05:05:03
60	658	2006-02-15 05:05:03
60	665	2006-02-15 05:05:03
60	679	2006-02-15 05:05:03
60	754	2006-02-15 05:05:03
60	771	2006-02-15 05:05:03
60	783	2006-02-15 05:05:03
60	784	2006-02-15 05:05:03
60	805	2006-02-15 05:05:03
60	830	2006-02-15 05:05:03
60	835	2006-02-15 05:05:03
60	928	2006-02-15 05:05:03
60	952	2006-02-15 05:05:03
60	971	2006-02-15 05:05:03
60	986	2006-02-15 05:05:03
61	235	2006-02-15 05:05:03
61	237	2006-02-15 05:05:03
61	307	2006-02-15 05:05:03
61	362	2006-02-15 05:05:03
61	372	2006-02-15 05:05:03
61	374	2006-02-15 05:05:03
61	423	2006-02-15 05:05:03
61	433	2006-02-15 05:05:03
61	508	2006-02-15 05:05:03
61	518	2006-02-15 05:05:03
61	519	2006-02-15 05:05:03
61	535	2006-02-15 05:05:03
61	537	2006-02-15 05:05:03
61	585	2006-02-15 05:05:03
61	639	2006-02-15 05:05:03
61	648	2006-02-15 05:05:03
61	649	2006-02-15 05:05:03
61	703	2006-02-15 05:05:03
61	752	2006-02-15 05:05:03
61	766	2006-02-15 05:05:03
61	767	2006-02-15 05:05:03
61	780	2006-02-15 05:05:03
61	831	2006-02-15 05:05:03
61	832	2006-02-15 05:05:03
61	990	2006-02-15 05:05:03
62	6	2006-02-15 05:05:03
62	42	2006-02-15 05:05:03
62	54	2006-02-15 05:05:03
62	100	2006-02-15 05:05:03
62	101	2006-02-15 05:05:03
62	129	2006-02-15 05:05:03
62	198	2006-02-15 05:05:03
62	211	2006-02-15 05:05:03
62	231	2006-02-15 05:05:03
62	272	2006-02-15 05:05:03
62	295	2006-02-15 05:05:03
62	337	2006-02-15 05:05:03
62	375	2006-02-15 05:05:03
62	385	2006-02-15 05:05:03
62	393	2006-02-15 05:05:03
62	398	2006-02-15 05:05:03
62	406	2006-02-15 05:05:03
62	413	2006-02-15 05:05:03
62	428	2006-02-15 05:05:03
62	445	2006-02-15 05:05:03
62	457	2006-02-15 05:05:03
62	465	2006-02-15 05:05:03
62	688	2006-02-15 05:05:03
62	707	2006-02-15 05:05:03
62	719	2006-02-15 05:05:03
62	951	2006-02-15 05:05:03
62	981	2006-02-15 05:05:03
62	988	2006-02-15 05:05:03
62	990	2006-02-15 05:05:03
63	73	2006-02-15 05:05:03
63	134	2006-02-15 05:05:03
63	167	2006-02-15 05:05:03
63	208	2006-02-15 05:05:03
63	225	2006-02-15 05:05:03
63	248	2006-02-15 05:05:03
63	249	2006-02-15 05:05:03
63	278	2006-02-15 05:05:03
63	392	2006-02-15 05:05:03
63	517	2006-02-15 05:05:03
63	633	2006-02-15 05:05:03
63	763	2006-02-15 05:05:03
63	781	2006-02-15 05:05:03
63	809	2006-02-15 05:05:03
63	893	2006-02-15 05:05:03
63	932	2006-02-15 05:05:03
63	944	2006-02-15 05:05:03
63	945	2006-02-15 05:05:03
63	981	2006-02-15 05:05:03
64	3	2006-02-15 05:05:03
64	10	2006-02-15 05:05:03
64	37	2006-02-15 05:05:03
64	87	2006-02-15 05:05:03
64	88	2006-02-15 05:05:03
64	124	2006-02-15 05:05:03
64	197	2006-02-15 05:05:03
64	280	2006-02-15 05:05:03
64	291	2006-02-15 05:05:03
64	307	2006-02-15 05:05:03
64	335	2006-02-15 05:05:03
64	345	2006-02-15 05:05:03
64	448	2006-02-15 05:05:03
64	469	2006-02-15 05:05:03
64	471	2006-02-15 05:05:03
64	506	2006-02-15 05:05:03
64	543	2006-02-15 05:05:03
64	557	2006-02-15 05:05:03
64	569	2006-02-15 05:05:03
64	572	2006-02-15 05:05:03
64	597	2006-02-15 05:05:03
64	616	2006-02-15 05:05:03
64	646	2006-02-15 05:05:03
64	694	2006-02-15 05:05:03
64	832	2006-02-15 05:05:03
64	852	2006-02-15 05:05:03
64	860	2006-02-15 05:05:03
64	921	2006-02-15 05:05:03
64	925	2006-02-15 05:05:03
64	980	2006-02-15 05:05:03
65	39	2006-02-15 05:05:03
65	46	2006-02-15 05:05:03
65	97	2006-02-15 05:05:03
65	106	2006-02-15 05:05:03
65	117	2006-02-15 05:05:03
65	125	2006-02-15 05:05:03
65	158	2006-02-15 05:05:03
65	276	2006-02-15 05:05:03
65	305	2006-02-15 05:05:03
65	338	2006-02-15 05:05:03
65	347	2006-02-15 05:05:03
65	371	2006-02-15 05:05:03
65	398	2006-02-15 05:05:03
65	471	2006-02-15 05:05:03
65	475	2006-02-15 05:05:03
65	476	2006-02-15 05:05:03
65	491	2006-02-15 05:05:03
65	496	2006-02-15 05:05:03
65	516	2006-02-15 05:05:03
65	517	2006-02-15 05:05:03
65	541	2006-02-15 05:05:03
65	556	2006-02-15 05:05:03
65	571	2006-02-15 05:05:03
65	577	2006-02-15 05:05:03
65	615	2006-02-15 05:05:03
65	658	2006-02-15 05:05:03
65	683	2006-02-15 05:05:03
65	694	2006-02-15 05:05:03
65	714	2006-02-15 05:05:03
65	735	2006-02-15 05:05:03
65	852	2006-02-15 05:05:03
65	938	2006-02-15 05:05:03
65	951	2006-02-15 05:05:03
65	965	2006-02-15 05:05:03
66	55	2006-02-15 05:05:03
66	143	2006-02-15 05:05:03
66	207	2006-02-15 05:05:03
66	226	2006-02-15 05:05:03
66	229	2006-02-15 05:05:03
66	230	2006-02-15 05:05:03
66	283	2006-02-15 05:05:03
66	300	2006-02-15 05:05:03
66	342	2006-02-15 05:05:03
66	350	2006-02-15 05:05:03
66	361	2006-02-15 05:05:03
66	376	2006-02-15 05:05:03
66	424	2006-02-15 05:05:03
66	434	2006-02-15 05:05:03
66	553	2006-02-15 05:05:03
66	608	2006-02-15 05:05:03
66	676	2006-02-15 05:05:03
66	697	2006-02-15 05:05:03
66	706	2006-02-15 05:05:03
66	725	2006-02-15 05:05:03
66	769	2006-02-15 05:05:03
66	793	2006-02-15 05:05:03
66	829	2006-02-15 05:05:03
66	871	2006-02-15 05:05:03
66	909	2006-02-15 05:05:03
66	915	2006-02-15 05:05:03
66	928	2006-02-15 05:05:03
66	951	2006-02-15 05:05:03
66	957	2006-02-15 05:05:03
66	960	2006-02-15 05:05:03
66	999	2006-02-15 05:05:03
67	24	2006-02-15 05:05:03
67	57	2006-02-15 05:05:03
67	67	2006-02-15 05:05:03
67	144	2006-02-15 05:05:03
67	242	2006-02-15 05:05:03
67	244	2006-02-15 05:05:03
67	256	2006-02-15 05:05:03
67	408	2006-02-15 05:05:03
67	477	2006-02-15 05:05:03
67	496	2006-02-15 05:05:03
67	512	2006-02-15 05:05:03
67	576	2006-02-15 05:05:03
67	601	2006-02-15 05:05:03
67	725	2006-02-15 05:05:03
67	726	2006-02-15 05:05:03
67	731	2006-02-15 05:05:03
67	766	2006-02-15 05:05:03
67	861	2006-02-15 05:05:03
67	870	2006-02-15 05:05:03
67	915	2006-02-15 05:05:03
67	945	2006-02-15 05:05:03
67	972	2006-02-15 05:05:03
67	981	2006-02-15 05:05:03
68	9	2006-02-15 05:05:03
68	45	2006-02-15 05:05:03
68	133	2006-02-15 05:05:03
68	161	2006-02-15 05:05:03
68	205	2006-02-15 05:05:03
68	213	2006-02-15 05:05:03
68	215	2006-02-15 05:05:03
68	255	2006-02-15 05:05:03
68	296	2006-02-15 05:05:03
68	315	2006-02-15 05:05:03
68	325	2006-02-15 05:05:03
68	331	2006-02-15 05:05:03
68	347	2006-02-15 05:05:03
68	357	2006-02-15 05:05:03
68	378	2006-02-15 05:05:03
68	380	2006-02-15 05:05:03
68	386	2006-02-15 05:05:03
68	396	2006-02-15 05:05:03
68	435	2006-02-15 05:05:03
68	497	2006-02-15 05:05:03
68	607	2006-02-15 05:05:03
68	654	2006-02-15 05:05:03
68	665	2006-02-15 05:05:03
68	671	2006-02-15 05:05:03
68	706	2006-02-15 05:05:03
68	747	2006-02-15 05:05:03
68	834	2006-02-15 05:05:03
68	839	2006-02-15 05:05:03
68	840	2006-02-15 05:05:03
68	971	2006-02-15 05:05:03
69	15	2006-02-15 05:05:03
69	88	2006-02-15 05:05:03
69	111	2006-02-15 05:05:03
69	202	2006-02-15 05:05:03
69	236	2006-02-15 05:05:03
69	292	2006-02-15 05:05:03
69	300	2006-02-15 05:05:03
69	306	2006-02-15 05:05:03
69	374	2006-02-15 05:05:03
69	396	2006-02-15 05:05:03
69	452	2006-02-15 05:05:03
69	466	2006-02-15 05:05:03
69	529	2006-02-15 05:05:03
69	612	2006-02-15 05:05:03
69	720	2006-02-15 05:05:03
69	722	2006-02-15 05:05:03
69	761	2006-02-15 05:05:03
69	791	2006-02-15 05:05:03
69	864	2006-02-15 05:05:03
69	877	2006-02-15 05:05:03
69	914	2006-02-15 05:05:03
70	50	2006-02-15 05:05:03
70	53	2006-02-15 05:05:03
70	92	2006-02-15 05:05:03
70	202	2006-02-15 05:05:03
70	227	2006-02-15 05:05:03
70	249	2006-02-15 05:05:03
70	290	2006-02-15 05:05:03
70	304	2006-02-15 05:05:03
70	343	2006-02-15 05:05:03
70	414	2006-02-15 05:05:03
70	453	2006-02-15 05:05:03
70	466	2006-02-15 05:05:03
70	504	2006-02-15 05:05:03
70	584	2006-02-15 05:05:03
70	628	2006-02-15 05:05:03
70	654	2006-02-15 05:05:03
70	725	2006-02-15 05:05:03
70	823	2006-02-15 05:05:03
70	834	2006-02-15 05:05:03
70	856	2006-02-15 05:05:03
70	869	2006-02-15 05:05:03
70	953	2006-02-15 05:05:03
70	964	2006-02-15 05:05:03
71	26	2006-02-15 05:05:03
71	52	2006-02-15 05:05:03
71	233	2006-02-15 05:05:03
71	317	2006-02-15 05:05:03
71	359	2006-02-15 05:05:03
71	362	2006-02-15 05:05:03
71	385	2006-02-15 05:05:03
71	399	2006-02-15 05:05:03
71	450	2006-02-15 05:05:03
71	532	2006-02-15 05:05:03
71	560	2006-02-15 05:05:03
71	574	2006-02-15 05:05:03
71	638	2006-02-15 05:05:03
71	773	2006-02-15 05:05:03
71	833	2006-02-15 05:05:03
71	874	2006-02-15 05:05:03
71	918	2006-02-15 05:05:03
71	956	2006-02-15 05:05:03
72	34	2006-02-15 05:05:03
72	144	2006-02-15 05:05:03
72	237	2006-02-15 05:05:03
72	249	2006-02-15 05:05:03
72	286	2006-02-15 05:05:03
72	296	2006-02-15 05:05:03
72	325	2006-02-15 05:05:03
72	331	2006-02-15 05:05:03
72	405	2006-02-15 05:05:03
72	450	2006-02-15 05:05:03
72	550	2006-02-15 05:05:03
72	609	2006-02-15 05:05:03
72	623	2006-02-15 05:05:03
72	636	2006-02-15 05:05:03
72	640	2006-02-15 05:05:03
72	665	2006-02-15 05:05:03
72	718	2006-02-15 05:05:03
72	743	2006-02-15 05:05:03
72	757	2006-02-15 05:05:03
72	773	2006-02-15 05:05:03
72	854	2006-02-15 05:05:03
72	865	2006-02-15 05:05:03
72	938	2006-02-15 05:05:03
72	956	2006-02-15 05:05:03
72	964	2006-02-15 05:05:03
72	969	2006-02-15 05:05:03
73	36	2006-02-15 05:05:03
73	45	2006-02-15 05:05:03
73	51	2006-02-15 05:05:03
73	77	2006-02-15 05:05:03
73	148	2006-02-15 05:05:03
73	245	2006-02-15 05:05:03
73	275	2006-02-15 05:05:03
73	322	2006-02-15 05:05:03
73	374	2006-02-15 05:05:03
73	379	2006-02-15 05:05:03
73	467	2006-02-15 05:05:03
73	548	2006-02-15 05:05:03
73	561	2006-02-15 05:05:03
73	562	2006-02-15 05:05:03
73	565	2006-02-15 05:05:03
73	627	2006-02-15 05:05:03
73	666	2006-02-15 05:05:03
73	667	2006-02-15 05:05:03
73	707	2006-02-15 05:05:03
73	748	2006-02-15 05:05:03
73	772	2006-02-15 05:05:03
73	823	2006-02-15 05:05:03
73	936	2006-02-15 05:05:03
73	946	2006-02-15 05:05:03
73	950	2006-02-15 05:05:03
73	998	2006-02-15 05:05:03
74	28	2006-02-15 05:05:03
74	44	2006-02-15 05:05:03
74	117	2006-02-15 05:05:03
74	185	2006-02-15 05:05:03
74	192	2006-02-15 05:05:03
74	203	2006-02-15 05:05:03
74	263	2006-02-15 05:05:03
74	321	2006-02-15 05:05:03
74	415	2006-02-15 05:05:03
74	484	2006-02-15 05:05:03
74	503	2006-02-15 05:05:03
74	537	2006-02-15 05:05:03
74	543	2006-02-15 05:05:03
74	617	2006-02-15 05:05:03
74	626	2006-02-15 05:05:03
74	637	2006-02-15 05:05:03
74	663	2006-02-15 05:05:03
74	704	2006-02-15 05:05:03
74	720	2006-02-15 05:05:03
74	747	2006-02-15 05:05:03
74	780	2006-02-15 05:05:03
74	804	2006-02-15 05:05:03
74	834	2006-02-15 05:05:03
74	836	2006-02-15 05:05:03
74	848	2006-02-15 05:05:03
74	872	2006-02-15 05:05:03
74	902	2006-02-15 05:05:03
74	956	2006-02-15 05:05:03
75	12	2006-02-15 05:05:03
75	34	2006-02-15 05:05:03
75	143	2006-02-15 05:05:03
75	170	2006-02-15 05:05:03
75	222	2006-02-15 05:05:03
75	301	2006-02-15 05:05:03
75	347	2006-02-15 05:05:03
75	372	2006-02-15 05:05:03
75	436	2006-02-15 05:05:03
75	445	2006-02-15 05:05:03
75	446	2006-02-15 05:05:03
75	492	2006-02-15 05:05:03
75	498	2006-02-15 05:05:03
75	508	2006-02-15 05:05:03
75	541	2006-02-15 05:05:03
75	547	2006-02-15 05:05:03
75	579	2006-02-15 05:05:03
75	645	2006-02-15 05:05:03
75	667	2006-02-15 05:05:03
75	744	2006-02-15 05:05:03
75	764	2006-02-15 05:05:03
75	780	2006-02-15 05:05:03
75	870	2006-02-15 05:05:03
75	920	2006-02-15 05:05:03
76	60	2006-02-15 05:05:03
76	66	2006-02-15 05:05:03
76	68	2006-02-15 05:05:03
76	95	2006-02-15 05:05:03
76	122	2006-02-15 05:05:03
76	187	2006-02-15 05:05:03
76	223	2006-02-15 05:05:03
76	234	2006-02-15 05:05:03
76	251	2006-02-15 05:05:03
76	348	2006-02-15 05:05:03
76	444	2006-02-15 05:05:03
76	464	2006-02-15 05:05:03
76	474	2006-02-15 05:05:03
76	498	2006-02-15 05:05:03
76	568	2006-02-15 05:05:03
76	604	2006-02-15 05:05:03
76	606	2006-02-15 05:05:03
76	642	2006-02-15 05:05:03
76	648	2006-02-15 05:05:03
76	650	2006-02-15 05:05:03
76	709	2006-02-15 05:05:03
76	760	2006-02-15 05:05:03
76	765	2006-02-15 05:05:03
76	781	2006-02-15 05:05:03
76	850	2006-02-15 05:05:03
76	862	2006-02-15 05:05:03
76	866	2006-02-15 05:05:03
76	870	2006-02-15 05:05:03
76	912	2006-02-15 05:05:03
76	935	2006-02-15 05:05:03
76	958	2006-02-15 05:05:03
77	13	2006-02-15 05:05:03
77	22	2006-02-15 05:05:03
77	40	2006-02-15 05:05:03
77	73	2006-02-15 05:05:03
77	78	2006-02-15 05:05:03
77	153	2006-02-15 05:05:03
77	224	2006-02-15 05:05:03
77	240	2006-02-15 05:05:03
77	245	2006-02-15 05:05:03
77	261	2006-02-15 05:05:03
77	343	2006-02-15 05:05:03
77	442	2006-02-15 05:05:03
77	458	2006-02-15 05:05:03
77	538	2006-02-15 05:05:03
77	566	2006-02-15 05:05:03
77	612	2006-02-15 05:05:03
77	635	2006-02-15 05:05:03
77	694	2006-02-15 05:05:03
77	749	2006-02-15 05:05:03
77	938	2006-02-15 05:05:03
77	943	2006-02-15 05:05:03
77	963	2006-02-15 05:05:03
77	969	2006-02-15 05:05:03
77	993	2006-02-15 05:05:03
78	86	2006-02-15 05:05:03
78	239	2006-02-15 05:05:03
78	260	2006-02-15 05:05:03
78	261	2006-02-15 05:05:03
78	265	2006-02-15 05:05:03
78	301	2006-02-15 05:05:03
78	387	2006-02-15 05:05:03
78	393	2006-02-15 05:05:03
78	428	2006-02-15 05:05:03
78	457	2006-02-15 05:05:03
78	505	2006-02-15 05:05:03
78	520	2006-02-15 05:05:03
78	530	2006-02-15 05:05:03
78	549	2006-02-15 05:05:03
78	552	2006-02-15 05:05:03
78	599	2006-02-15 05:05:03
78	670	2006-02-15 05:05:03
78	674	2006-02-15 05:05:03
78	689	2006-02-15 05:05:03
78	762	2006-02-15 05:05:03
78	767	2006-02-15 05:05:03
78	811	2006-02-15 05:05:03
78	852	2006-02-15 05:05:03
78	880	2006-02-15 05:05:03
78	963	2006-02-15 05:05:03
78	968	2006-02-15 05:05:03
79	32	2006-02-15 05:05:03
79	33	2006-02-15 05:05:03
79	40	2006-02-15 05:05:03
79	141	2006-02-15 05:05:03
79	205	2006-02-15 05:05:03
79	230	2006-02-15 05:05:03
79	242	2006-02-15 05:05:03
79	262	2006-02-15 05:05:03
79	267	2006-02-15 05:05:03
79	269	2006-02-15 05:05:03
79	299	2006-02-15 05:05:03
79	367	2006-02-15 05:05:03
79	428	2006-02-15 05:05:03
79	430	2006-02-15 05:05:03
79	473	2006-02-15 05:05:03
79	607	2006-02-15 05:05:03
79	628	2006-02-15 05:05:03
79	634	2006-02-15 05:05:03
79	646	2006-02-15 05:05:03
79	727	2006-02-15 05:05:03
79	750	2006-02-15 05:05:03
79	753	2006-02-15 05:05:03
79	769	2006-02-15 05:05:03
79	776	2006-02-15 05:05:03
79	788	2006-02-15 05:05:03
79	840	2006-02-15 05:05:03
79	853	2006-02-15 05:05:03
79	916	2006-02-15 05:05:03
80	69	2006-02-15 05:05:03
80	118	2006-02-15 05:05:03
80	124	2006-02-15 05:05:03
80	175	2006-02-15 05:05:03
80	207	2006-02-15 05:05:03
80	212	2006-02-15 05:05:03
80	260	2006-02-15 05:05:03
80	262	2006-02-15 05:05:03
80	280	2006-02-15 05:05:03
80	341	2006-02-15 05:05:03
80	342	2006-02-15 05:05:03
80	343	2006-02-15 05:05:03
80	362	2006-02-15 05:05:03
80	436	2006-02-15 05:05:03
80	475	2006-02-15 05:05:03
80	553	2006-02-15 05:05:03
80	619	2006-02-15 05:05:03
80	622	2006-02-15 05:05:03
80	680	2006-02-15 05:05:03
80	687	2006-02-15 05:05:03
80	688	2006-02-15 05:05:03
80	709	2006-02-15 05:05:03
80	788	2006-02-15 05:05:03
80	807	2006-02-15 05:05:03
80	858	2006-02-15 05:05:03
80	888	2006-02-15 05:05:03
80	941	2006-02-15 05:05:03
80	979	2006-02-15 05:05:03
81	4	2006-02-15 05:05:03
81	11	2006-02-15 05:05:03
81	59	2006-02-15 05:05:03
81	89	2006-02-15 05:05:03
81	178	2006-02-15 05:05:03
81	186	2006-02-15 05:05:03
81	194	2006-02-15 05:05:03
81	215	2006-02-15 05:05:03
81	219	2006-02-15 05:05:03
81	232	2006-02-15 05:05:03
81	260	2006-02-15 05:05:03
81	267	2006-02-15 05:05:03
81	268	2006-02-15 05:05:03
81	304	2006-02-15 05:05:03
81	332	2006-02-15 05:05:03
81	389	2006-02-15 05:05:03
81	398	2006-02-15 05:05:03
81	453	2006-02-15 05:05:03
81	458	2006-02-15 05:05:03
81	465	2006-02-15 05:05:03
81	505	2006-02-15 05:05:03
81	508	2006-02-15 05:05:03
81	527	2006-02-15 05:05:03
81	545	2006-02-15 05:05:03
81	564	2006-02-15 05:05:03
81	578	2006-02-15 05:05:03
81	579	2006-02-15 05:05:03
81	613	2006-02-15 05:05:03
81	619	2006-02-15 05:05:03
81	643	2006-02-15 05:05:03
81	692	2006-02-15 05:05:03
81	710	2006-02-15 05:05:03
81	729	2006-02-15 05:05:03
81	761	2006-02-15 05:05:03
81	827	2006-02-15 05:05:03
81	910	2006-02-15 05:05:03
82	17	2006-02-15 05:05:03
82	33	2006-02-15 05:05:03
82	104	2006-02-15 05:05:03
82	143	2006-02-15 05:05:03
82	188	2006-02-15 05:05:03
82	242	2006-02-15 05:05:03
82	247	2006-02-15 05:05:03
82	290	2006-02-15 05:05:03
82	306	2006-02-15 05:05:03
82	316	2006-02-15 05:05:03
82	344	2006-02-15 05:05:03
82	453	2006-02-15 05:05:03
82	468	2006-02-15 05:05:03
82	480	2006-02-15 05:05:03
82	497	2006-02-15 05:05:03
82	503	2006-02-15 05:05:03
82	527	2006-02-15 05:05:03
82	551	2006-02-15 05:05:03
82	561	2006-02-15 05:05:03
82	750	2006-02-15 05:05:03
82	787	2006-02-15 05:05:03
82	802	2006-02-15 05:05:03
82	838	2006-02-15 05:05:03
82	839	2006-02-15 05:05:03
82	870	2006-02-15 05:05:03
82	877	2006-02-15 05:05:03
82	893	2006-02-15 05:05:03
82	911	2006-02-15 05:05:03
82	954	2006-02-15 05:05:03
82	978	2006-02-15 05:05:03
82	985	2006-02-15 05:05:03
83	49	2006-02-15 05:05:03
83	52	2006-02-15 05:05:03
83	58	2006-02-15 05:05:03
83	110	2006-02-15 05:05:03
83	120	2006-02-15 05:05:03
83	121	2006-02-15 05:05:03
83	135	2006-02-15 05:05:03
83	165	2006-02-15 05:05:03
83	217	2006-02-15 05:05:03
83	247	2006-02-15 05:05:03
83	249	2006-02-15 05:05:03
83	263	2006-02-15 05:05:03
83	268	2006-02-15 05:05:03
83	279	2006-02-15 05:05:03
83	281	2006-02-15 05:05:03
83	339	2006-02-15 05:05:03
83	340	2006-02-15 05:05:03
83	369	2006-02-15 05:05:03
83	412	2006-02-15 05:05:03
83	519	2006-02-15 05:05:03
83	529	2006-02-15 05:05:03
83	615	2006-02-15 05:05:03
83	631	2006-02-15 05:05:03
83	655	2006-02-15 05:05:03
83	672	2006-02-15 05:05:03
83	686	2006-02-15 05:05:03
83	719	2006-02-15 05:05:03
83	764	2006-02-15 05:05:03
83	777	2006-02-15 05:05:03
83	784	2006-02-15 05:05:03
83	833	2006-02-15 05:05:03
83	873	2006-02-15 05:05:03
83	932	2006-02-15 05:05:03
84	19	2006-02-15 05:05:03
84	39	2006-02-15 05:05:03
84	46	2006-02-15 05:05:03
84	175	2006-02-15 05:05:03
84	238	2006-02-15 05:05:03
84	281	2006-02-15 05:05:03
84	290	2006-02-15 05:05:03
84	312	2006-02-15 05:05:03
84	317	2006-02-15 05:05:03
84	413	2006-02-15 05:05:03
84	414	2006-02-15 05:05:03
84	460	2006-02-15 05:05:03
84	479	2006-02-15 05:05:03
84	491	2006-02-15 05:05:03
84	529	2006-02-15 05:05:03
84	540	2006-02-15 05:05:03
84	566	2006-02-15 05:05:03
84	574	2006-02-15 05:05:03
84	589	2006-02-15 05:05:03
84	616	2006-02-15 05:05:03
84	646	2006-02-15 05:05:03
84	703	2006-02-15 05:05:03
84	729	2006-02-15 05:05:03
84	764	2006-02-15 05:05:03
84	782	2006-02-15 05:05:03
84	809	2006-02-15 05:05:03
84	830	2006-02-15 05:05:03
84	843	2006-02-15 05:05:03
84	887	2006-02-15 05:05:03
84	975	2006-02-15 05:05:03
84	996	2006-02-15 05:05:03
85	2	2006-02-15 05:05:03
85	14	2006-02-15 05:05:03
85	72	2006-02-15 05:05:03
85	85	2006-02-15 05:05:03
85	92	2006-02-15 05:05:03
85	148	2006-02-15 05:05:03
85	216	2006-02-15 05:05:03
85	290	2006-02-15 05:05:03
85	296	2006-02-15 05:05:03
85	297	2006-02-15 05:05:03
85	337	2006-02-15 05:05:03
85	383	2006-02-15 05:05:03
85	421	2006-02-15 05:05:03
85	446	2006-02-15 05:05:03
85	461	2006-02-15 05:05:03
85	475	2006-02-15 05:05:03
85	478	2006-02-15 05:05:03
85	522	2006-02-15 05:05:03
85	543	2006-02-15 05:05:03
85	558	2006-02-15 05:05:03
85	591	2006-02-15 05:05:03
85	630	2006-02-15 05:05:03
85	678	2006-02-15 05:05:03
85	711	2006-02-15 05:05:03
85	761	2006-02-15 05:05:03
85	812	2006-02-15 05:05:03
85	869	2006-02-15 05:05:03
85	875	2006-02-15 05:05:03
85	895	2006-02-15 05:05:03
85	957	2006-02-15 05:05:03
85	960	2006-02-15 05:05:03
86	137	2006-02-15 05:05:03
86	163	2006-02-15 05:05:03
86	196	2006-02-15 05:05:03
86	216	2006-02-15 05:05:03
86	249	2006-02-15 05:05:03
86	303	2006-02-15 05:05:03
86	331	2006-02-15 05:05:03
86	364	2006-02-15 05:05:03
86	391	2006-02-15 05:05:03
86	432	2006-02-15 05:05:03
86	482	2006-02-15 05:05:03
86	486	2006-02-15 05:05:03
86	519	2006-02-15 05:05:03
86	520	2006-02-15 05:05:03
86	548	2006-02-15 05:05:03
86	623	2006-02-15 05:05:03
86	631	2006-02-15 05:05:03
86	636	2006-02-15 05:05:03
86	752	2006-02-15 05:05:03
86	760	2006-02-15 05:05:03
86	808	2006-02-15 05:05:03
86	857	2006-02-15 05:05:03
86	878	2006-02-15 05:05:03
86	893	2006-02-15 05:05:03
86	905	2006-02-15 05:05:03
86	923	2006-02-15 05:05:03
86	929	2006-02-15 05:05:03
87	48	2006-02-15 05:05:03
87	157	2006-02-15 05:05:03
87	161	2006-02-15 05:05:03
87	199	2006-02-15 05:05:03
87	207	2006-02-15 05:05:03
87	250	2006-02-15 05:05:03
87	253	2006-02-15 05:05:03
87	312	2006-02-15 05:05:03
87	421	2006-02-15 05:05:03
87	570	2006-02-15 05:05:03
87	599	2006-02-15 05:05:03
87	606	2006-02-15 05:05:03
87	654	2006-02-15 05:05:03
87	679	2006-02-15 05:05:03
87	706	2006-02-15 05:05:03
87	718	2006-02-15 05:05:03
87	721	2006-02-15 05:05:03
87	830	2006-02-15 05:05:03
87	870	2006-02-15 05:05:03
87	952	2006-02-15 05:05:03
87	961	2006-02-15 05:05:03
88	4	2006-02-15 05:05:03
88	76	2006-02-15 05:05:03
88	87	2006-02-15 05:05:03
88	128	2006-02-15 05:05:03
88	170	2006-02-15 05:05:03
88	193	2006-02-15 05:05:03
88	234	2006-02-15 05:05:03
88	304	2006-02-15 05:05:03
88	602	2006-02-15 05:05:03
88	620	2006-02-15 05:05:03
88	668	2006-02-15 05:05:03
88	717	2006-02-15 05:05:03
88	785	2006-02-15 05:05:03
88	819	2006-02-15 05:05:03
88	839	2006-02-15 05:05:03
88	881	2006-02-15 05:05:03
88	908	2006-02-15 05:05:03
88	929	2006-02-15 05:05:03
88	940	2006-02-15 05:05:03
88	968	2006-02-15 05:05:03
89	47	2006-02-15 05:05:03
89	103	2006-02-15 05:05:03
89	117	2006-02-15 05:05:03
89	162	2006-02-15 05:05:03
89	182	2006-02-15 05:05:03
89	187	2006-02-15 05:05:03
89	212	2006-02-15 05:05:03
89	254	2006-02-15 05:05:03
89	266	2006-02-15 05:05:03
89	306	2006-02-15 05:05:03
89	342	2006-02-15 05:05:03
89	406	2006-02-15 05:05:03
89	410	2006-02-15 05:05:03
89	446	2006-02-15 05:05:03
89	473	2006-02-15 05:05:03
89	488	2006-02-15 05:05:03
89	529	2006-02-15 05:05:03
89	542	2006-02-15 05:05:03
89	564	2006-02-15 05:05:03
89	697	2006-02-15 05:05:03
89	833	2006-02-15 05:05:03
89	864	2006-02-15 05:05:03
89	970	2006-02-15 05:05:03
89	976	2006-02-15 05:05:03
90	2	2006-02-15 05:05:03
90	11	2006-02-15 05:05:03
90	100	2006-02-15 05:05:03
90	197	2006-02-15 05:05:03
90	212	2006-02-15 05:05:03
90	262	2006-02-15 05:05:03
90	303	2006-02-15 05:05:03
90	330	2006-02-15 05:05:03
90	363	2006-02-15 05:05:03
90	374	2006-02-15 05:05:03
90	384	2006-02-15 05:05:03
90	385	2006-02-15 05:05:03
90	391	2006-02-15 05:05:03
90	406	2006-02-15 05:05:03
90	433	2006-02-15 05:05:03
90	442	2006-02-15 05:05:03
90	451	2006-02-15 05:05:03
90	520	2006-02-15 05:05:03
90	529	2006-02-15 05:05:03
90	542	2006-02-15 05:05:03
90	586	2006-02-15 05:05:03
90	633	2006-02-15 05:05:03
90	663	2006-02-15 05:05:03
90	676	2006-02-15 05:05:03
90	771	2006-02-15 05:05:03
90	817	2006-02-15 05:05:03
90	838	2006-02-15 05:05:03
90	855	2006-02-15 05:05:03
90	858	2006-02-15 05:05:03
90	868	2006-02-15 05:05:03
90	880	2006-02-15 05:05:03
90	901	2006-02-15 05:05:03
90	925	2006-02-15 05:05:03
91	13	2006-02-15 05:05:03
91	25	2006-02-15 05:05:03
91	48	2006-02-15 05:05:03
91	176	2006-02-15 05:05:03
91	181	2006-02-15 05:05:03
91	190	2006-02-15 05:05:03
91	335	2006-02-15 05:05:03
91	416	2006-02-15 05:05:03
91	447	2006-02-15 05:05:03
91	480	2006-02-15 05:05:03
91	493	2006-02-15 05:05:03
91	509	2006-02-15 05:05:03
91	511	2006-02-15 05:05:03
91	608	2006-02-15 05:05:03
91	807	2006-02-15 05:05:03
91	829	2006-02-15 05:05:03
91	849	2006-02-15 05:05:03
91	859	2006-02-15 05:05:03
91	941	2006-02-15 05:05:03
91	982	2006-02-15 05:05:03
92	90	2006-02-15 05:05:03
92	94	2006-02-15 05:05:03
92	103	2006-02-15 05:05:03
92	104	2006-02-15 05:05:03
92	123	2006-02-15 05:05:03
92	137	2006-02-15 05:05:03
92	207	2006-02-15 05:05:03
92	229	2006-02-15 05:05:03
92	338	2006-02-15 05:05:03
92	381	2006-02-15 05:05:03
92	436	2006-02-15 05:05:03
92	443	2006-02-15 05:05:03
92	453	2006-02-15 05:05:03
92	470	2006-02-15 05:05:03
92	505	2006-02-15 05:05:03
92	512	2006-02-15 05:05:03
92	543	2006-02-15 05:05:03
92	545	2006-02-15 05:05:03
92	547	2006-02-15 05:05:03
92	553	2006-02-15 05:05:03
92	564	2006-02-15 05:05:03
92	568	2006-02-15 05:05:03
92	618	2006-02-15 05:05:03
92	662	2006-02-15 05:05:03
92	686	2006-02-15 05:05:03
92	699	2006-02-15 05:05:03
92	712	2006-02-15 05:05:03
92	728	2006-02-15 05:05:03
92	802	2006-02-15 05:05:03
92	825	2006-02-15 05:05:03
92	838	2006-02-15 05:05:03
92	889	2006-02-15 05:05:03
92	929	2006-02-15 05:05:03
92	991	2006-02-15 05:05:03
93	71	2006-02-15 05:05:03
93	120	2006-02-15 05:05:03
93	124	2006-02-15 05:05:03
93	280	2006-02-15 05:05:03
93	325	2006-02-15 05:05:03
93	339	2006-02-15 05:05:03
93	427	2006-02-15 05:05:03
93	445	2006-02-15 05:05:03
93	453	2006-02-15 05:05:03
93	473	2006-02-15 05:05:03
93	573	2006-02-15 05:05:03
93	621	2006-02-15 05:05:03
93	644	2006-02-15 05:05:03
93	678	2006-02-15 05:05:03
93	680	2006-02-15 05:05:03
93	699	2006-02-15 05:05:03
93	744	2006-02-15 05:05:03
93	768	2006-02-15 05:05:03
93	777	2006-02-15 05:05:03
93	835	2006-02-15 05:05:03
93	856	2006-02-15 05:05:03
93	874	2006-02-15 05:05:03
93	909	2006-02-15 05:05:03
93	916	2006-02-15 05:05:03
93	982	2006-02-15 05:05:03
94	13	2006-02-15 05:05:03
94	60	2006-02-15 05:05:03
94	76	2006-02-15 05:05:03
94	122	2006-02-15 05:05:03
94	153	2006-02-15 05:05:03
94	193	2006-02-15 05:05:03
94	206	2006-02-15 05:05:03
94	228	2006-02-15 05:05:03
94	270	2006-02-15 05:05:03
94	275	2006-02-15 05:05:03
94	320	2006-02-15 05:05:03
94	322	2006-02-15 05:05:03
94	337	2006-02-15 05:05:03
94	354	2006-02-15 05:05:03
94	402	2006-02-15 05:05:03
94	428	2006-02-15 05:05:03
94	457	2006-02-15 05:05:03
94	473	2006-02-15 05:05:03
94	475	2006-02-15 05:05:03
94	512	2006-02-15 05:05:03
94	517	2006-02-15 05:05:03
94	521	2006-02-15 05:05:03
94	533	2006-02-15 05:05:03
94	540	2006-02-15 05:05:03
94	548	2006-02-15 05:05:03
94	551	2006-02-15 05:05:03
94	712	2006-02-15 05:05:03
94	713	2006-02-15 05:05:03
94	724	2006-02-15 05:05:03
94	775	2006-02-15 05:05:03
94	788	2006-02-15 05:05:03
94	950	2006-02-15 05:05:03
94	989	2006-02-15 05:05:03
95	22	2006-02-15 05:05:03
95	35	2006-02-15 05:05:03
95	47	2006-02-15 05:05:03
95	52	2006-02-15 05:05:03
95	65	2006-02-15 05:05:03
95	74	2006-02-15 05:05:03
95	126	2006-02-15 05:05:03
95	207	2006-02-15 05:05:03
95	245	2006-02-15 05:05:03
95	294	2006-02-15 05:05:03
95	301	2006-02-15 05:05:03
95	312	2006-02-15 05:05:03
95	329	2006-02-15 05:05:03
95	353	2006-02-15 05:05:03
95	375	2006-02-15 05:05:03
95	420	2006-02-15 05:05:03
95	424	2006-02-15 05:05:03
95	431	2006-02-15 05:05:03
95	498	2006-02-15 05:05:03
95	522	2006-02-15 05:05:03
95	546	2006-02-15 05:05:03
95	551	2006-02-15 05:05:03
95	619	2006-02-15 05:05:03
95	627	2006-02-15 05:05:03
95	690	2006-02-15 05:05:03
95	748	2006-02-15 05:05:03
95	813	2006-02-15 05:05:03
95	828	2006-02-15 05:05:03
95	855	2006-02-15 05:05:03
95	903	2006-02-15 05:05:03
95	923	2006-02-15 05:05:03
96	8	2006-02-15 05:05:03
96	36	2006-02-15 05:05:03
96	40	2006-02-15 05:05:03
96	54	2006-02-15 05:05:03
96	58	2006-02-15 05:05:03
96	66	2006-02-15 05:05:03
96	134	2006-02-15 05:05:03
96	209	2006-02-15 05:05:03
96	244	2006-02-15 05:05:03
96	320	2006-02-15 05:05:03
96	430	2006-02-15 05:05:03
96	452	2006-02-15 05:05:03
96	486	2006-02-15 05:05:03
96	572	2006-02-15 05:05:03
96	590	2006-02-15 05:05:03
96	661	2006-02-15 05:05:03
96	778	2006-02-15 05:05:03
96	832	2006-02-15 05:05:03
96	846	2006-02-15 05:05:03
96	874	2006-02-15 05:05:03
96	945	2006-02-15 05:05:03
96	968	2006-02-15 05:05:03
96	987	2006-02-15 05:05:03
97	143	2006-02-15 05:05:03
97	177	2006-02-15 05:05:03
97	188	2006-02-15 05:05:03
97	197	2006-02-15 05:05:03
97	256	2006-02-15 05:05:03
97	312	2006-02-15 05:05:03
97	342	2006-02-15 05:05:03
97	348	2006-02-15 05:05:03
97	358	2006-02-15 05:05:03
97	370	2006-02-15 05:05:03
97	437	2006-02-15 05:05:03
97	446	2006-02-15 05:05:03
97	466	2006-02-15 05:05:03
97	518	2006-02-15 05:05:03
97	553	2006-02-15 05:05:03
97	561	2006-02-15 05:05:03
97	641	2006-02-15 05:05:03
97	656	2006-02-15 05:05:03
97	728	2006-02-15 05:05:03
97	755	2006-02-15 05:05:03
97	757	2006-02-15 05:05:03
97	826	2006-02-15 05:05:03
97	862	2006-02-15 05:05:03
97	930	2006-02-15 05:05:03
97	933	2006-02-15 05:05:03
97	947	2006-02-15 05:05:03
97	951	2006-02-15 05:05:03
98	66	2006-02-15 05:05:03
98	72	2006-02-15 05:05:03
98	81	2006-02-15 05:05:03
98	87	2006-02-15 05:05:03
98	107	2006-02-15 05:05:03
98	120	2006-02-15 05:05:03
98	183	2006-02-15 05:05:03
98	194	2006-02-15 05:05:03
98	212	2006-02-15 05:05:03
98	297	2006-02-15 05:05:03
98	607	2006-02-15 05:05:03
98	634	2006-02-15 05:05:03
98	686	2006-02-15 05:05:03
98	705	2006-02-15 05:05:03
98	710	2006-02-15 05:05:03
98	721	2006-02-15 05:05:03
98	725	2006-02-15 05:05:03
98	734	2006-02-15 05:05:03
98	738	2006-02-15 05:05:03
98	765	2006-02-15 05:05:03
98	782	2006-02-15 05:05:03
98	824	2006-02-15 05:05:03
98	829	2006-02-15 05:05:03
98	912	2006-02-15 05:05:03
98	955	2006-02-15 05:05:03
98	985	2006-02-15 05:05:03
98	990	2006-02-15 05:05:03
99	7	2006-02-15 05:05:03
99	27	2006-02-15 05:05:03
99	84	2006-02-15 05:05:03
99	250	2006-02-15 05:05:03
99	322	2006-02-15 05:05:03
99	325	2006-02-15 05:05:03
99	381	2006-02-15 05:05:03
99	414	2006-02-15 05:05:03
99	475	2006-02-15 05:05:03
99	490	2006-02-15 05:05:03
99	512	2006-02-15 05:05:03
99	540	2006-02-15 05:05:03
99	572	2006-02-15 05:05:03
99	600	2006-02-15 05:05:03
99	618	2006-02-15 05:05:03
99	620	2006-02-15 05:05:03
99	622	2006-02-15 05:05:03
99	636	2006-02-15 05:05:03
99	672	2006-02-15 05:05:03
99	726	2006-02-15 05:05:03
99	741	2006-02-15 05:05:03
99	796	2006-02-15 05:05:03
99	835	2006-02-15 05:05:03
99	967	2006-02-15 05:05:03
99	978	2006-02-15 05:05:03
99	982	2006-02-15 05:05:03
100	17	2006-02-15 05:05:03
100	118	2006-02-15 05:05:03
100	250	2006-02-15 05:05:03
100	411	2006-02-15 05:05:03
100	414	2006-02-15 05:05:03
100	513	2006-02-15 05:05:03
100	563	2006-02-15 05:05:03
100	642	2006-02-15 05:05:03
100	714	2006-02-15 05:05:03
100	718	2006-02-15 05:05:03
100	759	2006-02-15 05:05:03
100	779	2006-02-15 05:05:03
100	815	2006-02-15 05:05:03
100	846	2006-02-15 05:05:03
100	850	2006-02-15 05:05:03
100	872	2006-02-15 05:05:03
100	877	2006-02-15 05:05:03
100	909	2006-02-15 05:05:03
100	919	2006-02-15 05:05:03
100	944	2006-02-15 05:05:03
100	967	2006-02-15 05:05:03
100	979	2006-02-15 05:05:03
100	991	2006-02-15 05:05:03
100	992	2006-02-15 05:05:03
101	60	2006-02-15 05:05:03
101	66	2006-02-15 05:05:03
101	85	2006-02-15 05:05:03
101	146	2006-02-15 05:05:03
101	189	2006-02-15 05:05:03
101	250	2006-02-15 05:05:03
101	255	2006-02-15 05:05:03
101	263	2006-02-15 05:05:03
101	275	2006-02-15 05:05:03
101	289	2006-02-15 05:05:03
101	491	2006-02-15 05:05:03
101	494	2006-02-15 05:05:03
101	511	2006-02-15 05:05:03
101	568	2006-02-15 05:05:03
101	608	2006-02-15 05:05:03
101	617	2006-02-15 05:05:03
101	655	2006-02-15 05:05:03
101	662	2006-02-15 05:05:03
101	700	2006-02-15 05:05:03
101	702	2006-02-15 05:05:03
101	758	2006-02-15 05:05:03
101	774	2006-02-15 05:05:03
101	787	2006-02-15 05:05:03
101	828	2006-02-15 05:05:03
101	841	2006-02-15 05:05:03
101	928	2006-02-15 05:05:03
101	932	2006-02-15 05:05:03
101	936	2006-02-15 05:05:03
101	941	2006-02-15 05:05:03
101	978	2006-02-15 05:05:03
101	980	2006-02-15 05:05:03
101	984	2006-02-15 05:05:03
101	988	2006-02-15 05:05:03
102	20	2006-02-15 05:05:03
102	34	2006-02-15 05:05:03
102	53	2006-02-15 05:05:03
102	123	2006-02-15 05:05:03
102	124	2006-02-15 05:05:03
102	194	2006-02-15 05:05:03
102	200	2006-02-15 05:05:03
102	205	2006-02-15 05:05:03
102	268	2006-02-15 05:05:03
102	326	2006-02-15 05:05:03
102	329	2006-02-15 05:05:03
102	334	2006-02-15 05:05:03
102	351	2006-02-15 05:05:03
102	418	2006-02-15 05:05:03
102	431	2006-02-15 05:05:03
102	446	2006-02-15 05:05:03
102	485	2006-02-15 05:05:03
102	508	2006-02-15 05:05:03
102	517	2006-02-15 05:05:03
102	521	2006-02-15 05:05:03
102	526	2006-02-15 05:05:03
102	529	2006-02-15 05:05:03
102	544	2006-02-15 05:05:03
102	600	2006-02-15 05:05:03
102	605	2006-02-15 05:05:03
102	606	2006-02-15 05:05:03
102	624	2006-02-15 05:05:03
102	631	2006-02-15 05:05:03
102	712	2006-02-15 05:05:03
102	728	2006-02-15 05:05:03
102	744	2006-02-15 05:05:03
102	796	2006-02-15 05:05:03
102	802	2006-02-15 05:05:03
102	810	2006-02-15 05:05:03
102	828	2006-02-15 05:05:03
102	837	2006-02-15 05:05:03
102	845	2006-02-15 05:05:03
102	852	2006-02-15 05:05:03
102	958	2006-02-15 05:05:03
102	979	2006-02-15 05:05:03
102	980	2006-02-15 05:05:03
103	5	2006-02-15 05:05:03
103	118	2006-02-15 05:05:03
103	130	2006-02-15 05:05:03
103	197	2006-02-15 05:05:03
103	199	2006-02-15 05:05:03
103	206	2006-02-15 05:05:03
103	215	2006-02-15 05:05:03
103	221	2006-02-15 05:05:03
103	271	2006-02-15 05:05:03
103	285	2006-02-15 05:05:03
103	315	2006-02-15 05:05:03
103	318	2006-02-15 05:05:03
103	333	2006-02-15 05:05:03
103	347	2006-02-15 05:05:03
103	356	2006-02-15 05:05:03
103	360	2006-02-15 05:05:03
103	378	2006-02-15 05:05:03
103	437	2006-02-15 05:05:03
103	585	2006-02-15 05:05:03
103	609	2006-02-15 05:05:03
103	639	2006-02-15 05:05:03
103	643	2006-02-15 05:05:03
103	692	2006-02-15 05:05:03
103	735	2006-02-15 05:05:03
103	822	2006-02-15 05:05:03
103	895	2006-02-15 05:05:03
103	903	2006-02-15 05:05:03
103	912	2006-02-15 05:05:03
103	942	2006-02-15 05:05:03
103	956	2006-02-15 05:05:03
104	19	2006-02-15 05:05:03
104	39	2006-02-15 05:05:03
104	40	2006-02-15 05:05:03
104	59	2006-02-15 05:05:03
104	70	2006-02-15 05:05:03
104	136	2006-02-15 05:05:03
104	156	2006-02-15 05:05:03
104	184	2006-02-15 05:05:03
104	198	2006-02-15 05:05:03
104	233	2006-02-15 05:05:03
104	259	2006-02-15 05:05:03
104	287	2006-02-15 05:05:03
104	309	2006-02-15 05:05:03
104	313	2006-02-15 05:05:03
104	394	2006-02-15 05:05:03
104	401	2006-02-15 05:05:03
104	463	2006-02-15 05:05:03
104	506	2006-02-15 05:05:03
104	516	2006-02-15 05:05:03
104	583	2006-02-15 05:05:03
104	600	2006-02-15 05:05:03
104	607	2006-02-15 05:05:03
104	657	2006-02-15 05:05:03
104	677	2006-02-15 05:05:03
104	739	2006-02-15 05:05:03
104	892	2006-02-15 05:05:03
104	904	2006-02-15 05:05:03
104	926	2006-02-15 05:05:03
104	945	2006-02-15 05:05:03
104	984	2006-02-15 05:05:03
104	999	2006-02-15 05:05:03
105	12	2006-02-15 05:05:03
105	15	2006-02-15 05:05:03
105	21	2006-02-15 05:05:03
105	29	2006-02-15 05:05:03
105	42	2006-02-15 05:05:03
105	116	2006-02-15 05:05:03
105	158	2006-02-15 05:05:03
105	239	2006-02-15 05:05:03
105	280	2006-02-15 05:05:03
105	283	2006-02-15 05:05:03
105	315	2006-02-15 05:05:03
105	333	2006-02-15 05:05:03
105	372	2006-02-15 05:05:03
105	377	2006-02-15 05:05:03
105	530	2006-02-15 05:05:03
105	558	2006-02-15 05:05:03
105	561	2006-02-15 05:05:03
105	606	2006-02-15 05:05:03
105	649	2006-02-15 05:05:03
105	686	2006-02-15 05:05:03
105	750	2006-02-15 05:05:03
105	795	2006-02-15 05:05:03
105	831	2006-02-15 05:05:03
105	835	2006-02-15 05:05:03
105	858	2006-02-15 05:05:03
105	864	2006-02-15 05:05:03
105	893	2006-02-15 05:05:03
105	906	2006-02-15 05:05:03
105	910	2006-02-15 05:05:03
105	915	2006-02-15 05:05:03
105	954	2006-02-15 05:05:03
105	990	2006-02-15 05:05:03
105	993	2006-02-15 05:05:03
105	994	2006-02-15 05:05:03
106	44	2006-02-15 05:05:03
106	83	2006-02-15 05:05:03
106	108	2006-02-15 05:05:03
106	126	2006-02-15 05:05:03
106	136	2006-02-15 05:05:03
106	166	2006-02-15 05:05:03
106	189	2006-02-15 05:05:03
106	194	2006-02-15 05:05:03
106	204	2006-02-15 05:05:03
106	229	2006-02-15 05:05:03
106	241	2006-02-15 05:05:03
106	345	2006-02-15 05:05:03
106	365	2006-02-15 05:05:03
106	399	2006-02-15 05:05:03
106	439	2006-02-15 05:05:03
106	457	2006-02-15 05:05:03
106	469	2006-02-15 05:05:03
106	500	2006-02-15 05:05:03
106	505	2006-02-15 05:05:03
106	559	2006-02-15 05:05:03
106	566	2006-02-15 05:05:03
106	585	2006-02-15 05:05:03
106	639	2006-02-15 05:05:03
106	654	2006-02-15 05:05:03
106	659	2006-02-15 05:05:03
106	675	2006-02-15 05:05:03
106	687	2006-02-15 05:05:03
106	752	2006-02-15 05:05:03
106	763	2006-02-15 05:05:03
106	780	2006-02-15 05:05:03
106	858	2006-02-15 05:05:03
106	866	2006-02-15 05:05:03
106	881	2006-02-15 05:05:03
106	894	2006-02-15 05:05:03
106	934	2006-02-15 05:05:03
107	62	2006-02-15 05:05:03
107	112	2006-02-15 05:05:03
107	133	2006-02-15 05:05:03
107	136	2006-02-15 05:05:03
107	138	2006-02-15 05:05:03
107	162	2006-02-15 05:05:03
107	165	2006-02-15 05:05:03
107	172	2006-02-15 05:05:03
107	209	2006-02-15 05:05:03
107	220	2006-02-15 05:05:03
107	239	2006-02-15 05:05:03
107	277	2006-02-15 05:05:03
107	292	2006-02-15 05:05:03
107	338	2006-02-15 05:05:03
107	348	2006-02-15 05:05:03
107	369	2006-02-15 05:05:03
107	388	2006-02-15 05:05:03
107	392	2006-02-15 05:05:03
107	409	2006-02-15 05:05:03
107	430	2006-02-15 05:05:03
107	445	2006-02-15 05:05:03
107	454	2006-02-15 05:05:03
107	458	2006-02-15 05:05:03
107	467	2006-02-15 05:05:03
107	520	2006-02-15 05:05:03
107	534	2006-02-15 05:05:03
107	548	2006-02-15 05:05:03
107	571	2006-02-15 05:05:03
107	574	2006-02-15 05:05:03
107	603	2006-02-15 05:05:03
107	606	2006-02-15 05:05:03
107	637	2006-02-15 05:05:03
107	774	2006-02-15 05:05:03
107	781	2006-02-15 05:05:03
107	796	2006-02-15 05:05:03
107	831	2006-02-15 05:05:03
107	849	2006-02-15 05:05:03
107	859	2006-02-15 05:05:03
107	879	2006-02-15 05:05:03
107	905	2006-02-15 05:05:03
107	973	2006-02-15 05:05:03
107	977	2006-02-15 05:05:03
108	1	2006-02-15 05:05:03
108	6	2006-02-15 05:05:03
108	9	2006-02-15 05:05:03
108	137	2006-02-15 05:05:03
108	208	2006-02-15 05:05:03
108	219	2006-02-15 05:05:03
108	242	2006-02-15 05:05:03
108	278	2006-02-15 05:05:03
108	302	2006-02-15 05:05:03
108	350	2006-02-15 05:05:03
108	378	2006-02-15 05:05:03
108	379	2006-02-15 05:05:03
108	495	2006-02-15 05:05:03
108	507	2006-02-15 05:05:03
108	517	2006-02-15 05:05:03
108	561	2006-02-15 05:05:03
108	567	2006-02-15 05:05:03
108	648	2006-02-15 05:05:03
108	652	2006-02-15 05:05:03
108	655	2006-02-15 05:05:03
108	673	2006-02-15 05:05:03
108	693	2006-02-15 05:05:03
108	696	2006-02-15 05:05:03
108	702	2006-02-15 05:05:03
108	721	2006-02-15 05:05:03
108	733	2006-02-15 05:05:03
108	741	2006-02-15 05:05:03
108	744	2006-02-15 05:05:03
108	887	2006-02-15 05:05:03
108	892	2006-02-15 05:05:03
108	894	2006-02-15 05:05:03
108	920	2006-02-15 05:05:03
108	958	2006-02-15 05:05:03
108	966	2006-02-15 05:05:03
109	12	2006-02-15 05:05:03
109	48	2006-02-15 05:05:03
109	77	2006-02-15 05:05:03
109	157	2006-02-15 05:05:03
109	174	2006-02-15 05:05:03
109	190	2006-02-15 05:05:03
109	243	2006-02-15 05:05:03
109	281	2006-02-15 05:05:03
109	393	2006-02-15 05:05:03
109	463	2006-02-15 05:05:03
109	622	2006-02-15 05:05:03
109	657	2006-02-15 05:05:03
109	694	2006-02-15 05:05:03
109	700	2006-02-15 05:05:03
109	732	2006-02-15 05:05:03
109	753	2006-02-15 05:05:03
109	785	2006-02-15 05:05:03
109	786	2006-02-15 05:05:03
109	863	2006-02-15 05:05:03
109	885	2006-02-15 05:05:03
109	955	2006-02-15 05:05:03
109	967	2006-02-15 05:05:03
110	8	2006-02-15 05:05:03
110	27	2006-02-15 05:05:03
110	62	2006-02-15 05:05:03
110	120	2006-02-15 05:05:03
110	126	2006-02-15 05:05:03
110	156	2006-02-15 05:05:03
110	292	2006-02-15 05:05:03
110	343	2006-02-15 05:05:03
110	360	2006-02-15 05:05:03
110	369	2006-02-15 05:05:03
110	435	2006-02-15 05:05:03
110	513	2006-02-15 05:05:03
110	525	2006-02-15 05:05:03
110	539	2006-02-15 05:05:03
110	545	2006-02-15 05:05:03
110	625	2006-02-15 05:05:03
110	650	2006-02-15 05:05:03
110	801	2006-02-15 05:05:03
110	912	2006-02-15 05:05:03
110	961	2006-02-15 05:05:03
110	987	2006-02-15 05:05:03
111	61	2006-02-15 05:05:03
111	78	2006-02-15 05:05:03
111	98	2006-02-15 05:05:03
111	162	2006-02-15 05:05:03
111	179	2006-02-15 05:05:03
111	194	2006-02-15 05:05:03
111	325	2006-02-15 05:05:03
111	359	2006-02-15 05:05:03
111	382	2006-02-15 05:05:03
111	403	2006-02-15 05:05:03
111	407	2006-02-15 05:05:03
111	414	2006-02-15 05:05:03
111	474	2006-02-15 05:05:03
111	489	2006-02-15 05:05:03
111	508	2006-02-15 05:05:03
111	555	2006-02-15 05:05:03
111	603	2006-02-15 05:05:03
111	608	2006-02-15 05:05:03
111	643	2006-02-15 05:05:03
111	669	2006-02-15 05:05:03
111	679	2006-02-15 05:05:03
111	680	2006-02-15 05:05:03
111	699	2006-02-15 05:05:03
111	731	2006-02-15 05:05:03
111	732	2006-02-15 05:05:03
111	737	2006-02-15 05:05:03
111	744	2006-02-15 05:05:03
111	777	2006-02-15 05:05:03
111	847	2006-02-15 05:05:03
111	894	2006-02-15 05:05:03
111	919	2006-02-15 05:05:03
111	962	2006-02-15 05:05:03
111	973	2006-02-15 05:05:03
112	34	2006-02-15 05:05:03
112	37	2006-02-15 05:05:03
112	151	2006-02-15 05:05:03
112	173	2006-02-15 05:05:03
112	188	2006-02-15 05:05:03
112	231	2006-02-15 05:05:03
112	312	2006-02-15 05:05:03
112	322	2006-02-15 05:05:03
112	443	2006-02-15 05:05:03
112	450	2006-02-15 05:05:03
112	565	2006-02-15 05:05:03
112	603	2006-02-15 05:05:03
112	606	2006-02-15 05:05:03
112	654	2006-02-15 05:05:03
112	666	2006-02-15 05:05:03
112	700	2006-02-15 05:05:03
112	728	2006-02-15 05:05:03
112	772	2006-02-15 05:05:03
112	796	2006-02-15 05:05:03
112	817	2006-02-15 05:05:03
112	829	2006-02-15 05:05:03
112	856	2006-02-15 05:05:03
112	865	2006-02-15 05:05:03
112	869	2006-02-15 05:05:03
112	988	2006-02-15 05:05:03
113	35	2006-02-15 05:05:03
113	84	2006-02-15 05:05:03
113	116	2006-02-15 05:05:03
113	181	2006-02-15 05:05:03
113	218	2006-02-15 05:05:03
113	249	2006-02-15 05:05:03
113	258	2006-02-15 05:05:03
113	292	2006-02-15 05:05:03
113	322	2006-02-15 05:05:03
113	353	2006-02-15 05:05:03
113	403	2006-02-15 05:05:03
113	525	2006-02-15 05:05:03
113	642	2006-02-15 05:05:03
113	656	2006-02-15 05:05:03
113	674	2006-02-15 05:05:03
113	680	2006-02-15 05:05:03
113	700	2006-02-15 05:05:03
113	719	2006-02-15 05:05:03
113	723	2006-02-15 05:05:03
113	726	2006-02-15 05:05:03
113	732	2006-02-15 05:05:03
113	748	2006-02-15 05:05:03
113	838	2006-02-15 05:05:03
113	890	2006-02-15 05:05:03
113	921	2006-02-15 05:05:03
113	969	2006-02-15 05:05:03
113	981	2006-02-15 05:05:03
114	13	2006-02-15 05:05:03
114	68	2006-02-15 05:05:03
114	90	2006-02-15 05:05:03
114	162	2006-02-15 05:05:03
114	188	2006-02-15 05:05:03
114	194	2006-02-15 05:05:03
114	210	2006-02-15 05:05:03
114	237	2006-02-15 05:05:03
114	254	2006-02-15 05:05:03
114	305	2006-02-15 05:05:03
114	339	2006-02-15 05:05:03
114	420	2006-02-15 05:05:03
114	425	2006-02-15 05:05:03
114	452	2006-02-15 05:05:03
114	538	2006-02-15 05:05:03
114	619	2006-02-15 05:05:03
114	757	2006-02-15 05:05:03
114	807	2006-02-15 05:05:03
114	827	2006-02-15 05:05:03
114	841	2006-02-15 05:05:03
114	861	2006-02-15 05:05:03
114	866	2006-02-15 05:05:03
114	913	2006-02-15 05:05:03
114	961	2006-02-15 05:05:03
114	993	2006-02-15 05:05:03
115	49	2006-02-15 05:05:03
115	52	2006-02-15 05:05:03
115	245	2006-02-15 05:05:03
115	246	2006-02-15 05:05:03
115	277	2006-02-15 05:05:03
115	302	2006-02-15 05:05:03
115	379	2006-02-15 05:05:03
115	383	2006-02-15 05:05:03
115	391	2006-02-15 05:05:03
115	428	2006-02-15 05:05:03
115	506	2006-02-15 05:05:03
115	531	2006-02-15 05:05:03
115	607	2006-02-15 05:05:03
115	615	2006-02-15 05:05:03
115	661	2006-02-15 05:05:03
115	671	2006-02-15 05:05:03
115	686	2006-02-15 05:05:03
115	703	2006-02-15 05:05:03
115	714	2006-02-15 05:05:03
115	740	2006-02-15 05:05:03
115	754	2006-02-15 05:05:03
115	846	2006-02-15 05:05:03
115	887	2006-02-15 05:05:03
115	952	2006-02-15 05:05:03
115	955	2006-02-15 05:05:03
115	966	2006-02-15 05:05:03
115	985	2006-02-15 05:05:03
115	994	2006-02-15 05:05:03
116	36	2006-02-15 05:05:03
116	48	2006-02-15 05:05:03
116	88	2006-02-15 05:05:03
116	90	2006-02-15 05:05:03
116	105	2006-02-15 05:05:03
116	128	2006-02-15 05:05:03
116	336	2006-02-15 05:05:03
116	338	2006-02-15 05:05:03
116	384	2006-02-15 05:05:03
116	412	2006-02-15 05:05:03
116	420	2006-02-15 05:05:03
116	451	2006-02-15 05:05:03
116	481	2006-02-15 05:05:03
116	492	2006-02-15 05:05:03
116	584	2006-02-15 05:05:03
116	606	2006-02-15 05:05:03
116	622	2006-02-15 05:05:03
116	647	2006-02-15 05:05:03
116	653	2006-02-15 05:05:03
116	742	2006-02-15 05:05:03
116	784	2006-02-15 05:05:03
116	844	2006-02-15 05:05:03
116	939	2006-02-15 05:05:03
116	956	2006-02-15 05:05:03
117	10	2006-02-15 05:05:03
117	15	2006-02-15 05:05:03
117	42	2006-02-15 05:05:03
117	167	2006-02-15 05:05:03
117	178	2006-02-15 05:05:03
117	190	2006-02-15 05:05:03
117	197	2006-02-15 05:05:03
117	224	2006-02-15 05:05:03
117	246	2006-02-15 05:05:03
117	273	2006-02-15 05:05:03
117	298	2006-02-15 05:05:03
117	316	2006-02-15 05:05:03
117	337	2006-02-15 05:05:03
117	395	2006-02-15 05:05:03
117	423	2006-02-15 05:05:03
117	432	2006-02-15 05:05:03
117	459	2006-02-15 05:05:03
117	468	2006-02-15 05:05:03
117	550	2006-02-15 05:05:03
117	578	2006-02-15 05:05:03
117	707	2006-02-15 05:05:03
117	710	2006-02-15 05:05:03
117	738	2006-02-15 05:05:03
117	739	2006-02-15 05:05:03
117	778	2006-02-15 05:05:03
117	783	2006-02-15 05:05:03
117	785	2006-02-15 05:05:03
117	797	2006-02-15 05:05:03
117	812	2006-02-15 05:05:03
117	831	2006-02-15 05:05:03
117	864	2006-02-15 05:05:03
117	887	2006-02-15 05:05:03
117	926	2006-02-15 05:05:03
118	35	2006-02-15 05:05:03
118	39	2006-02-15 05:05:03
118	41	2006-02-15 05:05:03
118	49	2006-02-15 05:05:03
118	55	2006-02-15 05:05:03
118	136	2006-02-15 05:05:03
118	141	2006-02-15 05:05:03
118	151	2006-02-15 05:05:03
118	311	2006-02-15 05:05:03
118	384	2006-02-15 05:05:03
118	399	2006-02-15 05:05:03
118	499	2006-02-15 05:05:03
118	517	2006-02-15 05:05:03
118	553	2006-02-15 05:05:03
118	558	2006-02-15 05:05:03
118	572	2006-02-15 05:05:03
118	641	2006-02-15 05:05:03
118	656	2006-02-15 05:05:03
118	695	2006-02-15 05:05:03
118	735	2006-02-15 05:05:03
118	788	2006-02-15 05:05:03
118	852	2006-02-15 05:05:03
118	938	2006-02-15 05:05:03
118	957	2006-02-15 05:05:03
118	969	2006-02-15 05:05:03
119	21	2006-02-15 05:05:03
119	49	2006-02-15 05:05:03
119	64	2006-02-15 05:05:03
119	87	2006-02-15 05:05:03
119	143	2006-02-15 05:05:03
119	171	2006-02-15 05:05:03
119	172	2006-02-15 05:05:03
119	173	2006-02-15 05:05:03
119	381	2006-02-15 05:05:03
119	394	2006-02-15 05:05:03
119	412	2006-02-15 05:05:03
119	418	2006-02-15 05:05:03
119	454	2006-02-15 05:05:03
119	509	2006-02-15 05:05:03
119	521	2006-02-15 05:05:03
119	567	2006-02-15 05:05:03
119	570	2006-02-15 05:05:03
119	592	2006-02-15 05:05:03
119	614	2006-02-15 05:05:03
119	636	2006-02-15 05:05:03
119	649	2006-02-15 05:05:03
119	693	2006-02-15 05:05:03
119	738	2006-02-15 05:05:03
119	751	2006-02-15 05:05:03
119	782	2006-02-15 05:05:03
119	786	2006-02-15 05:05:03
119	788	2006-02-15 05:05:03
119	802	2006-02-15 05:05:03
119	858	2006-02-15 05:05:03
119	868	2006-02-15 05:05:03
119	900	2006-02-15 05:05:03
119	939	2006-02-15 05:05:03
120	57	2006-02-15 05:05:03
120	63	2006-02-15 05:05:03
120	144	2006-02-15 05:05:03
120	149	2006-02-15 05:05:03
120	208	2006-02-15 05:05:03
120	231	2006-02-15 05:05:03
120	238	2006-02-15 05:05:03
120	255	2006-02-15 05:05:03
120	414	2006-02-15 05:05:03
120	424	2006-02-15 05:05:03
120	489	2006-02-15 05:05:03
120	513	2006-02-15 05:05:03
120	590	2006-02-15 05:05:03
120	641	2006-02-15 05:05:03
120	642	2006-02-15 05:05:03
120	659	2006-02-15 05:05:03
120	682	2006-02-15 05:05:03
120	691	2006-02-15 05:05:03
120	715	2006-02-15 05:05:03
120	717	2006-02-15 05:05:03
120	722	2006-02-15 05:05:03
120	746	2006-02-15 05:05:03
120	830	2006-02-15 05:05:03
120	894	2006-02-15 05:05:03
120	898	2006-02-15 05:05:03
120	911	2006-02-15 05:05:03
120	994	2006-02-15 05:05:03
121	141	2006-02-15 05:05:03
121	154	2006-02-15 05:05:03
121	161	2006-02-15 05:05:03
121	170	2006-02-15 05:05:03
121	186	2006-02-15 05:05:03
121	198	2006-02-15 05:05:03
121	220	2006-02-15 05:05:03
121	222	2006-02-15 05:05:03
121	284	2006-02-15 05:05:03
121	297	2006-02-15 05:05:03
121	338	2006-02-15 05:05:03
121	353	2006-02-15 05:05:03
121	449	2006-02-15 05:05:03
121	479	2006-02-15 05:05:03
121	517	2006-02-15 05:05:03
121	633	2006-02-15 05:05:03
121	654	2006-02-15 05:05:03
121	658	2006-02-15 05:05:03
121	666	2006-02-15 05:05:03
121	771	2006-02-15 05:05:03
121	780	2006-02-15 05:05:03
121	847	2006-02-15 05:05:03
121	884	2006-02-15 05:05:03
121	885	2006-02-15 05:05:03
121	966	2006-02-15 05:05:03
122	22	2006-02-15 05:05:03
122	29	2006-02-15 05:05:03
122	76	2006-02-15 05:05:03
122	83	2006-02-15 05:05:03
122	157	2006-02-15 05:05:03
122	158	2006-02-15 05:05:03
122	166	2006-02-15 05:05:03
122	227	2006-02-15 05:05:03
122	238	2006-02-15 05:05:03
122	300	2006-02-15 05:05:03
122	307	2006-02-15 05:05:03
122	363	2006-02-15 05:05:03
122	470	2006-02-15 05:05:03
122	489	2006-02-15 05:05:03
122	491	2006-02-15 05:05:03
122	542	2006-02-15 05:05:03
122	620	2006-02-15 05:05:03
122	649	2006-02-15 05:05:03
122	654	2006-02-15 05:05:03
122	673	2006-02-15 05:05:03
122	718	2006-02-15 05:05:03
122	795	2006-02-15 05:05:03
122	957	2006-02-15 05:05:03
122	961	2006-02-15 05:05:03
122	998	2006-02-15 05:05:03
123	3	2006-02-15 05:05:03
123	43	2006-02-15 05:05:03
123	67	2006-02-15 05:05:03
123	105	2006-02-15 05:05:03
123	148	2006-02-15 05:05:03
123	151	2006-02-15 05:05:03
123	185	2006-02-15 05:05:03
123	223	2006-02-15 05:05:03
123	234	2006-02-15 05:05:03
123	245	2006-02-15 05:05:03
123	246	2006-02-15 05:05:03
123	266	2006-02-15 05:05:03
123	286	2006-02-15 05:05:03
123	429	2006-02-15 05:05:03
123	442	2006-02-15 05:05:03
123	446	2006-02-15 05:05:03
123	479	2006-02-15 05:05:03
123	480	2006-02-15 05:05:03
123	494	2006-02-15 05:05:03
123	503	2006-02-15 05:05:03
123	530	2006-02-15 05:05:03
123	576	2006-02-15 05:05:03
123	577	2006-02-15 05:05:03
123	589	2006-02-15 05:05:03
123	593	2006-02-15 05:05:03
123	725	2006-02-15 05:05:03
123	730	2006-02-15 05:05:03
123	786	2006-02-15 05:05:03
123	860	2006-02-15 05:05:03
123	892	2006-02-15 05:05:03
123	926	2006-02-15 05:05:03
123	988	2006-02-15 05:05:03
124	22	2006-02-15 05:05:03
124	64	2006-02-15 05:05:03
124	106	2006-02-15 05:05:03
124	113	2006-02-15 05:05:03
124	190	2006-02-15 05:05:03
124	246	2006-02-15 05:05:03
124	260	2006-02-15 05:05:03
124	263	2006-02-15 05:05:03
124	289	2006-02-15 05:05:03
124	306	2006-02-15 05:05:03
124	312	2006-02-15 05:05:03
124	322	2006-02-15 05:05:03
124	343	2006-02-15 05:05:03
124	449	2006-02-15 05:05:03
124	468	2006-02-15 05:05:03
124	539	2006-02-15 05:05:03
124	601	2006-02-15 05:05:03
124	726	2006-02-15 05:05:03
124	742	2006-02-15 05:05:03
124	775	2006-02-15 05:05:03
124	785	2006-02-15 05:05:03
124	814	2006-02-15 05:05:03
124	858	2006-02-15 05:05:03
124	882	2006-02-15 05:05:03
124	987	2006-02-15 05:05:03
124	997	2006-02-15 05:05:03
125	62	2006-02-15 05:05:03
125	98	2006-02-15 05:05:03
125	100	2006-02-15 05:05:03
125	114	2006-02-15 05:05:03
125	175	2006-02-15 05:05:03
125	188	2006-02-15 05:05:03
125	204	2006-02-15 05:05:03
125	238	2006-02-15 05:05:03
125	250	2006-02-15 05:05:03
125	324	2006-02-15 05:05:03
125	338	2006-02-15 05:05:03
125	361	2006-02-15 05:05:03
125	367	2006-02-15 05:05:03
125	395	2006-02-15 05:05:03
125	414	2006-02-15 05:05:03
125	428	2006-02-15 05:05:03
125	429	2006-02-15 05:05:03
125	450	2006-02-15 05:05:03
125	497	2006-02-15 05:05:03
125	557	2006-02-15 05:05:03
125	568	2006-02-15 05:05:03
125	584	2006-02-15 05:05:03
125	602	2006-02-15 05:05:03
125	623	2006-02-15 05:05:03
125	664	2006-02-15 05:05:03
125	683	2006-02-15 05:05:03
125	710	2006-02-15 05:05:03
125	877	2006-02-15 05:05:03
125	908	2006-02-15 05:05:03
125	949	2006-02-15 05:05:03
125	965	2006-02-15 05:05:03
126	21	2006-02-15 05:05:03
126	34	2006-02-15 05:05:03
126	43	2006-02-15 05:05:03
126	58	2006-02-15 05:05:03
126	85	2006-02-15 05:05:03
126	96	2006-02-15 05:05:03
126	193	2006-02-15 05:05:03
126	194	2006-02-15 05:05:03
126	199	2006-02-15 05:05:03
126	256	2006-02-15 05:05:03
126	263	2006-02-15 05:05:03
126	288	2006-02-15 05:05:03
126	317	2006-02-15 05:05:03
126	347	2006-02-15 05:05:03
126	369	2006-02-15 05:05:03
126	370	2006-02-15 05:05:03
126	419	2006-02-15 05:05:03
126	468	2006-02-15 05:05:03
126	469	2006-02-15 05:05:03
126	545	2006-02-15 05:05:03
126	685	2006-02-15 05:05:03
126	836	2006-02-15 05:05:03
126	860	2006-02-15 05:05:03
127	36	2006-02-15 05:05:03
127	47	2006-02-15 05:05:03
127	48	2006-02-15 05:05:03
127	79	2006-02-15 05:05:03
127	119	2006-02-15 05:05:03
127	141	2006-02-15 05:05:03
127	157	2006-02-15 05:05:03
127	202	2006-02-15 05:05:03
127	286	2006-02-15 05:05:03
127	333	2006-02-15 05:05:03
127	354	2006-02-15 05:05:03
127	366	2006-02-15 05:05:03
127	382	2006-02-15 05:05:03
127	388	2006-02-15 05:05:03
127	411	2006-02-15 05:05:03
127	459	2006-02-15 05:05:03
127	553	2006-02-15 05:05:03
127	573	2006-02-15 05:05:03
127	613	2006-02-15 05:05:03
127	617	2006-02-15 05:05:03
127	641	2006-02-15 05:05:03
127	710	2006-02-15 05:05:03
127	727	2006-02-15 05:05:03
127	749	2006-02-15 05:05:03
127	763	2006-02-15 05:05:03
127	771	2006-02-15 05:05:03
127	791	2006-02-15 05:05:03
127	819	2006-02-15 05:05:03
127	839	2006-02-15 05:05:03
127	846	2006-02-15 05:05:03
127	911	2006-02-15 05:05:03
127	953	2006-02-15 05:05:03
127	970	2006-02-15 05:05:03
128	26	2006-02-15 05:05:03
128	82	2006-02-15 05:05:03
128	119	2006-02-15 05:05:03
128	168	2006-02-15 05:05:03
128	212	2006-02-15 05:05:03
128	238	2006-02-15 05:05:03
128	299	2006-02-15 05:05:03
128	312	2006-02-15 05:05:03
128	326	2006-02-15 05:05:03
128	336	2006-02-15 05:05:03
128	345	2006-02-15 05:05:03
128	407	2006-02-15 05:05:03
128	462	2006-02-15 05:05:03
128	485	2006-02-15 05:05:03
128	516	2006-02-15 05:05:03
128	564	2006-02-15 05:05:03
128	614	2006-02-15 05:05:03
128	650	2006-02-15 05:05:03
128	665	2006-02-15 05:05:03
128	671	2006-02-15 05:05:03
128	693	2006-02-15 05:05:03
128	696	2006-02-15 05:05:03
128	759	2006-02-15 05:05:03
128	774	2006-02-15 05:05:03
128	814	2006-02-15 05:05:03
128	899	2006-02-15 05:05:03
128	912	2006-02-15 05:05:03
128	944	2006-02-15 05:05:03
128	949	2006-02-15 05:05:03
128	965	2006-02-15 05:05:03
129	56	2006-02-15 05:05:03
129	89	2006-02-15 05:05:03
129	101	2006-02-15 05:05:03
129	166	2006-02-15 05:05:03
129	202	2006-02-15 05:05:03
129	230	2006-02-15 05:05:03
129	247	2006-02-15 05:05:03
129	249	2006-02-15 05:05:03
129	348	2006-02-15 05:05:03
129	367	2006-02-15 05:05:03
129	391	2006-02-15 05:05:03
129	418	2006-02-15 05:05:03
129	431	2006-02-15 05:05:03
129	452	2006-02-15 05:05:03
129	471	2006-02-15 05:05:03
129	520	2006-02-15 05:05:03
129	597	2006-02-15 05:05:03
129	602	2006-02-15 05:05:03
129	640	2006-02-15 05:05:03
129	669	2006-02-15 05:05:03
129	684	2006-02-15 05:05:03
129	705	2006-02-15 05:05:03
129	805	2006-02-15 05:05:03
129	826	2006-02-15 05:05:03
129	834	2006-02-15 05:05:03
129	857	2006-02-15 05:05:03
129	910	2006-02-15 05:05:03
129	920	2006-02-15 05:05:03
129	938	2006-02-15 05:05:03
129	962	2006-02-15 05:05:03
130	9	2006-02-15 05:05:03
130	26	2006-02-15 05:05:03
130	37	2006-02-15 05:05:03
130	43	2006-02-15 05:05:03
130	49	2006-02-15 05:05:03
130	57	2006-02-15 05:05:03
130	107	2006-02-15 05:05:03
130	112	2006-02-15 05:05:03
130	208	2006-02-15 05:05:03
130	326	2006-02-15 05:05:03
130	375	2006-02-15 05:05:03
130	416	2006-02-15 05:05:03
130	431	2006-02-15 05:05:03
130	452	2006-02-15 05:05:03
130	453	2006-02-15 05:05:03
130	478	2006-02-15 05:05:03
130	507	2006-02-15 05:05:03
130	525	2006-02-15 05:05:03
130	549	2006-02-15 05:05:03
130	592	2006-02-15 05:05:03
130	702	2006-02-15 05:05:03
130	725	2006-02-15 05:05:03
130	764	2006-02-15 05:05:03
130	809	2006-02-15 05:05:03
130	869	2006-02-15 05:05:03
130	930	2006-02-15 05:05:03
130	981	2006-02-15 05:05:03
131	48	2006-02-15 05:05:03
131	66	2006-02-15 05:05:03
131	94	2006-02-15 05:05:03
131	120	2006-02-15 05:05:03
131	147	2006-02-15 05:05:03
131	206	2006-02-15 05:05:03
131	320	2006-02-15 05:05:03
131	383	2006-02-15 05:05:03
131	432	2006-02-15 05:05:03
131	436	2006-02-15 05:05:03
131	450	2006-02-15 05:05:03
131	479	2006-02-15 05:05:03
131	494	2006-02-15 05:05:03
131	515	2006-02-15 05:05:03
131	539	2006-02-15 05:05:03
131	590	2006-02-15 05:05:03
131	647	2006-02-15 05:05:03
131	693	2006-02-15 05:05:03
131	713	2006-02-15 05:05:03
131	770	2006-02-15 05:05:03
131	798	2006-02-15 05:05:03
131	809	2006-02-15 05:05:03
131	875	2006-02-15 05:05:03
131	881	2006-02-15 05:05:03
131	921	2006-02-15 05:05:03
132	81	2006-02-15 05:05:03
132	82	2006-02-15 05:05:03
132	133	2006-02-15 05:05:03
132	156	2006-02-15 05:05:03
132	162	2006-02-15 05:05:03
132	311	2006-02-15 05:05:03
132	345	2006-02-15 05:05:03
132	377	2006-02-15 05:05:03
132	410	2006-02-15 05:05:03
132	538	2006-02-15 05:05:03
132	562	2006-02-15 05:05:03
132	586	2006-02-15 05:05:03
132	626	2006-02-15 05:05:03
132	637	2006-02-15 05:05:03
132	698	2006-02-15 05:05:03
132	756	2006-02-15 05:05:03
132	806	2006-02-15 05:05:03
132	897	2006-02-15 05:05:03
132	899	2006-02-15 05:05:03
132	904	2006-02-15 05:05:03
132	930	2006-02-15 05:05:03
132	987	2006-02-15 05:05:03
133	7	2006-02-15 05:05:03
133	51	2006-02-15 05:05:03
133	133	2006-02-15 05:05:03
133	172	2006-02-15 05:05:03
133	210	2006-02-15 05:05:03
133	270	2006-02-15 05:05:03
133	280	2006-02-15 05:05:03
133	286	2006-02-15 05:05:03
133	338	2006-02-15 05:05:03
133	342	2006-02-15 05:05:03
133	351	2006-02-15 05:05:03
133	368	2006-02-15 05:05:03
133	385	2006-02-15 05:05:03
133	390	2006-02-15 05:05:03
133	397	2006-02-15 05:05:03
133	410	2006-02-15 05:05:03
133	452	2006-02-15 05:05:03
133	463	2006-02-15 05:05:03
133	514	2006-02-15 05:05:03
133	588	2006-02-15 05:05:03
133	594	2006-02-15 05:05:03
133	635	2006-02-15 05:05:03
133	652	2006-02-15 05:05:03
133	727	2006-02-15 05:05:03
133	806	2006-02-15 05:05:03
133	868	2006-02-15 05:05:03
133	882	2006-02-15 05:05:03
133	894	2006-02-15 05:05:03
133	933	2006-02-15 05:05:03
133	952	2006-02-15 05:05:03
134	132	2006-02-15 05:05:03
134	145	2006-02-15 05:05:03
134	161	2006-02-15 05:05:03
134	219	2006-02-15 05:05:03
134	243	2006-02-15 05:05:03
134	250	2006-02-15 05:05:03
134	278	2006-02-15 05:05:03
134	341	2006-02-15 05:05:03
134	386	2006-02-15 05:05:03
134	413	2006-02-15 05:05:03
134	558	2006-02-15 05:05:03
134	588	2006-02-15 05:05:03
134	624	2006-02-15 05:05:03
134	655	2006-02-15 05:05:03
134	683	2006-02-15 05:05:03
134	690	2006-02-15 05:05:03
134	861	2006-02-15 05:05:03
134	896	2006-02-15 05:05:03
134	897	2006-02-15 05:05:03
134	915	2006-02-15 05:05:03
134	927	2006-02-15 05:05:03
134	936	2006-02-15 05:05:03
135	35	2006-02-15 05:05:03
135	41	2006-02-15 05:05:03
135	65	2006-02-15 05:05:03
135	88	2006-02-15 05:05:03
135	170	2006-02-15 05:05:03
135	269	2006-02-15 05:05:03
135	320	2006-02-15 05:05:03
135	353	2006-02-15 05:05:03
135	357	2006-02-15 05:05:03
135	364	2006-02-15 05:05:03
135	455	2006-02-15 05:05:03
135	458	2006-02-15 05:05:03
135	484	2006-02-15 05:05:03
135	541	2006-02-15 05:05:03
135	553	2006-02-15 05:05:03
135	616	2006-02-15 05:05:03
135	628	2006-02-15 05:05:03
135	719	2006-02-15 05:05:03
135	814	2006-02-15 05:05:03
135	905	2006-02-15 05:05:03
136	20	2006-02-15 05:05:03
136	25	2006-02-15 05:05:03
136	33	2006-02-15 05:05:03
136	56	2006-02-15 05:05:03
136	61	2006-02-15 05:05:03
136	193	2006-02-15 05:05:03
136	214	2006-02-15 05:05:03
136	229	2006-02-15 05:05:03
136	243	2006-02-15 05:05:03
136	256	2006-02-15 05:05:03
136	262	2006-02-15 05:05:03
136	271	2006-02-15 05:05:03
136	288	2006-02-15 05:05:03
136	300	2006-02-15 05:05:03
136	364	2006-02-15 05:05:03
136	401	2006-02-15 05:05:03
136	414	2006-02-15 05:05:03
136	420	2006-02-15 05:05:03
136	474	2006-02-15 05:05:03
136	485	2006-02-15 05:05:03
136	542	2006-02-15 05:05:03
136	552	2006-02-15 05:05:03
136	620	2006-02-15 05:05:03
136	649	2006-02-15 05:05:03
136	686	2006-02-15 05:05:03
136	781	2006-02-15 05:05:03
136	806	2006-02-15 05:05:03
136	808	2006-02-15 05:05:03
136	818	2006-02-15 05:05:03
136	842	2006-02-15 05:05:03
136	933	2006-02-15 05:05:03
136	993	2006-02-15 05:05:03
137	6	2006-02-15 05:05:03
137	14	2006-02-15 05:05:03
137	56	2006-02-15 05:05:03
137	96	2006-02-15 05:05:03
137	160	2006-02-15 05:05:03
137	224	2006-02-15 05:05:03
137	249	2006-02-15 05:05:03
137	254	2006-02-15 05:05:03
137	263	2006-02-15 05:05:03
137	268	2006-02-15 05:05:03
137	304	2006-02-15 05:05:03
137	390	2006-02-15 05:05:03
137	410	2006-02-15 05:05:03
137	433	2006-02-15 05:05:03
137	446	2006-02-15 05:05:03
137	489	2006-02-15 05:05:03
137	530	2006-02-15 05:05:03
137	564	2006-02-15 05:05:03
137	603	2006-02-15 05:05:03
137	610	2006-02-15 05:05:03
137	688	2006-02-15 05:05:03
137	703	2006-02-15 05:05:03
137	745	2006-02-15 05:05:03
137	758	2006-02-15 05:05:03
137	832	2006-02-15 05:05:03
137	841	2006-02-15 05:05:03
137	917	2006-02-15 05:05:03
138	8	2006-02-15 05:05:03
138	52	2006-02-15 05:05:03
138	61	2006-02-15 05:05:03
138	125	2006-02-15 05:05:03
138	157	2006-02-15 05:05:03
138	214	2006-02-15 05:05:03
138	258	2006-02-15 05:05:03
138	376	2006-02-15 05:05:03
138	403	2006-02-15 05:05:03
138	446	2006-02-15 05:05:03
138	453	2006-02-15 05:05:03
138	508	2006-02-15 05:05:03
138	553	2006-02-15 05:05:03
138	561	2006-02-15 05:05:03
138	583	2006-02-15 05:05:03
138	627	2006-02-15 05:05:03
138	639	2006-02-15 05:05:03
138	695	2006-02-15 05:05:03
138	747	2006-02-15 05:05:03
138	879	2006-02-15 05:05:03
138	885	2006-02-15 05:05:03
138	923	2006-02-15 05:05:03
138	970	2006-02-15 05:05:03
138	989	2006-02-15 05:05:03
139	20	2006-02-15 05:05:03
139	35	2006-02-15 05:05:03
139	57	2006-02-15 05:05:03
139	74	2006-02-15 05:05:03
139	90	2006-02-15 05:05:03
139	107	2006-02-15 05:05:03
139	155	2006-02-15 05:05:03
139	170	2006-02-15 05:05:03
139	181	2006-02-15 05:05:03
139	200	2006-02-15 05:05:03
139	229	2006-02-15 05:05:03
139	233	2006-02-15 05:05:03
139	261	2006-02-15 05:05:03
139	262	2006-02-15 05:05:03
139	266	2006-02-15 05:05:03
139	282	2006-02-15 05:05:03
139	284	2006-02-15 05:05:03
139	373	2006-02-15 05:05:03
139	447	2006-02-15 05:05:03
139	489	2006-02-15 05:05:03
139	529	2006-02-15 05:05:03
139	540	2006-02-15 05:05:03
139	570	2006-02-15 05:05:03
139	602	2006-02-15 05:05:03
139	605	2006-02-15 05:05:03
139	636	2006-02-15 05:05:03
139	691	2006-02-15 05:05:03
139	706	2006-02-15 05:05:03
139	719	2006-02-15 05:05:03
139	744	2006-02-15 05:05:03
139	746	2006-02-15 05:05:03
139	862	2006-02-15 05:05:03
139	892	2006-02-15 05:05:03
140	27	2006-02-15 05:05:03
140	77	2006-02-15 05:05:03
140	112	2006-02-15 05:05:03
140	135	2006-02-15 05:05:03
140	185	2006-02-15 05:05:03
140	258	2006-02-15 05:05:03
140	370	2006-02-15 05:05:03
140	373	2006-02-15 05:05:03
140	498	2006-02-15 05:05:03
140	509	2006-02-15 05:05:03
140	576	2006-02-15 05:05:03
140	587	2006-02-15 05:05:03
140	599	2006-02-15 05:05:03
140	608	2006-02-15 05:05:03
140	647	2006-02-15 05:05:03
140	665	2006-02-15 05:05:03
140	670	2006-02-15 05:05:03
140	693	2006-02-15 05:05:03
140	702	2006-02-15 05:05:03
140	729	2006-02-15 05:05:03
140	730	2006-02-15 05:05:03
140	731	2006-02-15 05:05:03
140	736	2006-02-15 05:05:03
140	742	2006-02-15 05:05:03
140	778	2006-02-15 05:05:03
140	820	2006-02-15 05:05:03
140	830	2006-02-15 05:05:03
140	835	2006-02-15 05:05:03
140	857	2006-02-15 05:05:03
140	923	2006-02-15 05:05:03
140	934	2006-02-15 05:05:03
140	999	2006-02-15 05:05:03
141	43	2006-02-15 05:05:03
141	67	2006-02-15 05:05:03
141	188	2006-02-15 05:05:03
141	191	2006-02-15 05:05:03
141	207	2006-02-15 05:05:03
141	223	2006-02-15 05:05:03
141	341	2006-02-15 05:05:03
141	358	2006-02-15 05:05:03
141	380	2006-02-15 05:05:03
141	395	2006-02-15 05:05:03
141	467	2006-02-15 05:05:03
141	491	2006-02-15 05:05:03
141	589	2006-02-15 05:05:03
141	607	2006-02-15 05:05:03
141	673	2006-02-15 05:05:03
141	740	2006-02-15 05:05:03
141	752	2006-02-15 05:05:03
141	768	2006-02-15 05:05:03
141	772	2006-02-15 05:05:03
141	787	2006-02-15 05:05:03
141	821	2006-02-15 05:05:03
141	829	2006-02-15 05:05:03
141	840	2006-02-15 05:05:03
141	849	2006-02-15 05:05:03
141	862	2006-02-15 05:05:03
141	863	2006-02-15 05:05:03
141	909	2006-02-15 05:05:03
141	992	2006-02-15 05:05:03
142	10	2006-02-15 05:05:03
142	18	2006-02-15 05:05:03
142	107	2006-02-15 05:05:03
142	139	2006-02-15 05:05:03
142	186	2006-02-15 05:05:03
142	199	2006-02-15 05:05:03
142	248	2006-02-15 05:05:03
142	328	2006-02-15 05:05:03
142	350	2006-02-15 05:05:03
142	371	2006-02-15 05:05:03
142	470	2006-02-15 05:05:03
142	481	2006-02-15 05:05:03
142	494	2006-02-15 05:05:03
142	501	2006-02-15 05:05:03
142	504	2006-02-15 05:05:03
142	540	2006-02-15 05:05:03
142	554	2006-02-15 05:05:03
142	575	2006-02-15 05:05:03
142	608	2006-02-15 05:05:03
142	710	2006-02-15 05:05:03
142	712	2006-02-15 05:05:03
142	735	2006-02-15 05:05:03
142	759	2006-02-15 05:05:03
142	794	2006-02-15 05:05:03
142	842	2006-02-15 05:05:03
142	859	2006-02-15 05:05:03
142	863	2006-02-15 05:05:03
142	875	2006-02-15 05:05:03
142	906	2006-02-15 05:05:03
142	914	2006-02-15 05:05:03
142	999	2006-02-15 05:05:03
143	47	2006-02-15 05:05:03
143	79	2006-02-15 05:05:03
143	141	2006-02-15 05:05:03
143	175	2006-02-15 05:05:03
143	232	2006-02-15 05:05:03
143	239	2006-02-15 05:05:03
143	316	2006-02-15 05:05:03
143	339	2006-02-15 05:05:03
143	361	2006-02-15 05:05:03
143	386	2006-02-15 05:05:03
143	404	2006-02-15 05:05:03
143	457	2006-02-15 05:05:03
143	485	2006-02-15 05:05:03
143	497	2006-02-15 05:05:03
143	560	2006-02-15 05:05:03
143	576	2006-02-15 05:05:03
143	603	2006-02-15 05:05:03
143	613	2006-02-15 05:05:03
143	659	2006-02-15 05:05:03
143	660	2006-02-15 05:05:03
143	680	2006-02-15 05:05:03
143	687	2006-02-15 05:05:03
143	690	2006-02-15 05:05:03
143	706	2006-02-15 05:05:03
143	792	2006-02-15 05:05:03
143	821	2006-02-15 05:05:03
143	830	2006-02-15 05:05:03
143	872	2006-02-15 05:05:03
143	878	2006-02-15 05:05:03
143	906	2006-02-15 05:05:03
143	958	2006-02-15 05:05:03
144	18	2006-02-15 05:05:03
144	67	2006-02-15 05:05:03
144	79	2006-02-15 05:05:03
144	90	2006-02-15 05:05:03
144	99	2006-02-15 05:05:03
144	105	2006-02-15 05:05:03
144	123	2006-02-15 05:05:03
144	125	2006-02-15 05:05:03
144	127	2006-02-15 05:05:03
144	130	2006-02-15 05:05:03
144	135	2006-02-15 05:05:03
144	164	2006-02-15 05:05:03
144	184	2006-02-15 05:05:03
144	216	2006-02-15 05:05:03
144	228	2006-02-15 05:05:03
144	260	2006-02-15 05:05:03
144	272	2006-02-15 05:05:03
144	291	2006-02-15 05:05:03
144	293	2006-02-15 05:05:03
144	312	2006-02-15 05:05:03
144	393	2006-02-15 05:05:03
144	396	2006-02-15 05:05:03
144	473	2006-02-15 05:05:03
144	504	2006-02-15 05:05:03
144	540	2006-02-15 05:05:03
144	599	2006-02-15 05:05:03
144	668	2006-02-15 05:05:03
144	702	2006-02-15 05:05:03
144	753	2006-02-15 05:05:03
144	762	2006-02-15 05:05:03
144	776	2006-02-15 05:05:03
144	785	2006-02-15 05:05:03
144	845	2006-02-15 05:05:03
144	894	2006-02-15 05:05:03
144	953	2006-02-15 05:05:03
145	39	2006-02-15 05:05:03
145	109	2006-02-15 05:05:03
145	120	2006-02-15 05:05:03
145	154	2006-02-15 05:05:03
145	155	2006-02-15 05:05:03
145	243	2006-02-15 05:05:03
145	293	2006-02-15 05:05:03
145	402	2006-02-15 05:05:03
145	409	2006-02-15 05:05:03
145	457	2006-02-15 05:05:03
145	475	2006-02-15 05:05:03
145	487	2006-02-15 05:05:03
145	494	2006-02-15 05:05:03
145	527	2006-02-15 05:05:03
145	592	2006-02-15 05:05:03
145	625	2006-02-15 05:05:03
145	629	2006-02-15 05:05:03
145	641	2006-02-15 05:05:03
145	661	2006-02-15 05:05:03
145	664	2006-02-15 05:05:03
145	692	2006-02-15 05:05:03
145	713	2006-02-15 05:05:03
145	726	2006-02-15 05:05:03
145	748	2006-02-15 05:05:03
145	822	2006-02-15 05:05:03
145	893	2006-02-15 05:05:03
145	923	2006-02-15 05:05:03
145	953	2006-02-15 05:05:03
146	12	2006-02-15 05:05:03
146	16	2006-02-15 05:05:03
146	33	2006-02-15 05:05:03
146	117	2006-02-15 05:05:03
146	177	2006-02-15 05:05:03
146	191	2006-02-15 05:05:03
146	197	2006-02-15 05:05:03
146	207	2006-02-15 05:05:03
146	218	2006-02-15 05:05:03
146	278	2006-02-15 05:05:03
146	296	2006-02-15 05:05:03
146	314	2006-02-15 05:05:03
146	320	2006-02-15 05:05:03
146	372	2006-02-15 05:05:03
146	384	2006-02-15 05:05:03
146	402	2006-02-15 05:05:03
146	410	2006-02-15 05:05:03
146	427	2006-02-15 05:05:03
146	429	2006-02-15 05:05:03
146	512	2006-02-15 05:05:03
146	514	2006-02-15 05:05:03
146	571	2006-02-15 05:05:03
146	591	2006-02-15 05:05:03
146	720	2006-02-15 05:05:03
146	731	2006-02-15 05:05:03
146	734	2006-02-15 05:05:03
146	871	2006-02-15 05:05:03
146	909	2006-02-15 05:05:03
146	922	2006-02-15 05:05:03
146	945	2006-02-15 05:05:03
146	955	2006-02-15 05:05:03
146	966	2006-02-15 05:05:03
146	969	2006-02-15 05:05:03
147	4	2006-02-15 05:05:03
147	85	2006-02-15 05:05:03
147	131	2006-02-15 05:05:03
147	139	2006-02-15 05:05:03
147	145	2006-02-15 05:05:03
147	178	2006-02-15 05:05:03
147	251	2006-02-15 05:05:03
147	254	2006-02-15 05:05:03
147	295	2006-02-15 05:05:03
147	298	2006-02-15 05:05:03
147	305	2006-02-15 05:05:03
147	310	2006-02-15 05:05:03
147	318	2006-02-15 05:05:03
147	333	2006-02-15 05:05:03
147	341	2006-02-15 05:05:03
147	351	2006-02-15 05:05:03
147	394	2006-02-15 05:05:03
147	402	2006-02-15 05:05:03
147	405	2006-02-15 05:05:03
147	410	2006-02-15 05:05:03
147	431	2006-02-15 05:05:03
147	443	2006-02-15 05:05:03
147	508	2006-02-15 05:05:03
147	554	2006-02-15 05:05:03
147	563	2006-02-15 05:05:03
147	649	2006-02-15 05:05:03
147	688	2006-02-15 05:05:03
147	708	2006-02-15 05:05:03
147	864	2006-02-15 05:05:03
147	957	2006-02-15 05:05:03
147	987	2006-02-15 05:05:03
148	27	2006-02-15 05:05:03
148	57	2006-02-15 05:05:03
148	133	2006-02-15 05:05:03
148	149	2006-02-15 05:05:03
148	226	2006-02-15 05:05:03
148	342	2006-02-15 05:05:03
148	368	2006-02-15 05:05:03
148	422	2006-02-15 05:05:03
148	468	2006-02-15 05:05:03
148	633	2006-02-15 05:05:03
148	718	2006-02-15 05:05:03
148	768	2006-02-15 05:05:03
148	772	2006-02-15 05:05:03
148	792	2006-02-15 05:05:03
149	53	2006-02-15 05:05:03
149	72	2006-02-15 05:05:03
149	95	2006-02-15 05:05:03
149	118	2006-02-15 05:05:03
149	139	2006-02-15 05:05:03
149	146	2006-02-15 05:05:03
149	153	2006-02-15 05:05:03
149	159	2006-02-15 05:05:03
149	169	2006-02-15 05:05:03
149	178	2006-02-15 05:05:03
149	188	2006-02-15 05:05:03
149	193	2006-02-15 05:05:03
149	339	2006-02-15 05:05:03
149	354	2006-02-15 05:05:03
149	362	2006-02-15 05:05:03
149	365	2006-02-15 05:05:03
149	458	2006-02-15 05:05:03
149	631	2006-02-15 05:05:03
149	670	2006-02-15 05:05:03
149	685	2006-02-15 05:05:03
149	761	2006-02-15 05:05:03
149	782	2006-02-15 05:05:03
149	810	2006-02-15 05:05:03
149	811	2006-02-15 05:05:03
149	899	2006-02-15 05:05:03
149	905	2006-02-15 05:05:03
149	913	2006-02-15 05:05:03
149	921	2006-02-15 05:05:03
149	947	2006-02-15 05:05:03
149	949	2006-02-15 05:05:03
149	992	2006-02-15 05:05:03
150	23	2006-02-15 05:05:03
150	63	2006-02-15 05:05:03
150	75	2006-02-15 05:05:03
150	94	2006-02-15 05:05:03
150	105	2006-02-15 05:05:03
150	168	2006-02-15 05:05:03
150	190	2006-02-15 05:05:03
150	206	2006-02-15 05:05:03
150	233	2006-02-15 05:05:03
150	270	2006-02-15 05:05:03
150	285	2006-02-15 05:05:03
150	306	2006-02-15 05:05:03
150	386	2006-02-15 05:05:03
150	433	2006-02-15 05:05:03
150	446	2006-02-15 05:05:03
150	447	2006-02-15 05:05:03
150	468	2006-02-15 05:05:03
150	508	2006-02-15 05:05:03
150	542	2006-02-15 05:05:03
150	551	2006-02-15 05:05:03
150	629	2006-02-15 05:05:03
150	647	2006-02-15 05:05:03
150	672	2006-02-15 05:05:03
150	697	2006-02-15 05:05:03
150	728	2006-02-15 05:05:03
150	777	2006-02-15 05:05:03
150	854	2006-02-15 05:05:03
150	873	2006-02-15 05:05:03
150	880	2006-02-15 05:05:03
150	887	2006-02-15 05:05:03
150	889	2006-02-15 05:05:03
150	892	2006-02-15 05:05:03
150	953	2006-02-15 05:05:03
150	962	2006-02-15 05:05:03
151	131	2006-02-15 05:05:03
151	144	2006-02-15 05:05:03
151	167	2006-02-15 05:05:03
151	170	2006-02-15 05:05:03
151	217	2006-02-15 05:05:03
151	232	2006-02-15 05:05:03
151	342	2006-02-15 05:05:03
151	367	2006-02-15 05:05:03
151	370	2006-02-15 05:05:03
151	382	2006-02-15 05:05:03
151	451	2006-02-15 05:05:03
151	463	2006-02-15 05:05:03
151	482	2006-02-15 05:05:03
151	501	2006-02-15 05:05:03
151	527	2006-02-15 05:05:03
151	539	2006-02-15 05:05:03
151	570	2006-02-15 05:05:03
151	574	2006-02-15 05:05:03
151	634	2006-02-15 05:05:03
151	658	2006-02-15 05:05:03
151	665	2006-02-15 05:05:03
151	703	2006-02-15 05:05:03
151	880	2006-02-15 05:05:03
151	892	2006-02-15 05:05:03
151	895	2006-02-15 05:05:03
151	989	2006-02-15 05:05:03
152	59	2006-02-15 05:05:03
152	153	2006-02-15 05:05:03
152	217	2006-02-15 05:05:03
152	248	2006-02-15 05:05:03
152	318	2006-02-15 05:05:03
152	332	2006-02-15 05:05:03
152	475	2006-02-15 05:05:03
152	476	2006-02-15 05:05:03
152	578	2006-02-15 05:05:03
152	607	2006-02-15 05:05:03
152	611	2006-02-15 05:05:03
152	615	2006-02-15 05:05:03
152	674	2006-02-15 05:05:03
152	680	2006-02-15 05:05:03
152	729	2006-02-15 05:05:03
152	768	2006-02-15 05:05:03
152	821	2006-02-15 05:05:03
152	846	2006-02-15 05:05:03
152	891	2006-02-15 05:05:03
152	898	2006-02-15 05:05:03
152	927	2006-02-15 05:05:03
152	964	2006-02-15 05:05:03
152	968	2006-02-15 05:05:03
153	47	2006-02-15 05:05:03
153	64	2006-02-15 05:05:03
153	136	2006-02-15 05:05:03
153	180	2006-02-15 05:05:03
153	203	2006-02-15 05:05:03
153	231	2006-02-15 05:05:03
153	444	2006-02-15 05:05:03
153	476	2006-02-15 05:05:03
153	480	2006-02-15 05:05:03
153	486	2006-02-15 05:05:03
153	536	2006-02-15 05:05:03
153	627	2006-02-15 05:05:03
153	732	2006-02-15 05:05:03
153	756	2006-02-15 05:05:03
153	766	2006-02-15 05:05:03
153	817	2006-02-15 05:05:03
153	847	2006-02-15 05:05:03
153	919	2006-02-15 05:05:03
153	938	2006-02-15 05:05:03
153	988	2006-02-15 05:05:03
154	27	2006-02-15 05:05:03
154	111	2006-02-15 05:05:03
154	141	2006-02-15 05:05:03
154	158	2006-02-15 05:05:03
154	169	2006-02-15 05:05:03
154	170	2006-02-15 05:05:03
154	193	2006-02-15 05:05:03
154	208	2006-02-15 05:05:03
154	274	2006-02-15 05:05:03
154	276	2006-02-15 05:05:03
154	282	2006-02-15 05:05:03
154	299	2006-02-15 05:05:03
154	314	2006-02-15 05:05:03
154	396	2006-02-15 05:05:03
154	399	2006-02-15 05:05:03
154	421	2006-02-15 05:05:03
154	440	2006-02-15 05:05:03
154	467	2006-02-15 05:05:03
154	474	2006-02-15 05:05:03
154	489	2006-02-15 05:05:03
154	588	2006-02-15 05:05:03
154	602	2006-02-15 05:05:03
154	680	2006-02-15 05:05:03
154	698	2006-02-15 05:05:03
154	802	2006-02-15 05:05:03
154	842	2006-02-15 05:05:03
154	954	2006-02-15 05:05:03
154	988	2006-02-15 05:05:03
155	20	2006-02-15 05:05:03
155	67	2006-02-15 05:05:03
155	128	2006-02-15 05:05:03
155	153	2006-02-15 05:05:03
155	220	2006-02-15 05:05:03
155	249	2006-02-15 05:05:03
155	303	2006-02-15 05:05:03
155	312	2006-02-15 05:05:03
155	359	2006-02-15 05:05:03
155	361	2006-02-15 05:05:03
155	383	2006-02-15 05:05:03
155	387	2006-02-15 05:05:03
155	407	2006-02-15 05:05:03
155	427	2006-02-15 05:05:03
155	459	2006-02-15 05:05:03
155	513	2006-02-15 05:05:03
155	584	2006-02-15 05:05:03
155	590	2006-02-15 05:05:03
155	630	2006-02-15 05:05:03
155	688	2006-02-15 05:05:03
155	757	2006-02-15 05:05:03
155	768	2006-02-15 05:05:03
155	785	2006-02-15 05:05:03
155	849	2006-02-15 05:05:03
155	885	2006-02-15 05:05:03
155	890	2006-02-15 05:05:03
155	941	2006-02-15 05:05:03
155	966	2006-02-15 05:05:03
155	987	2006-02-15 05:05:03
155	997	2006-02-15 05:05:03
155	1000	2006-02-15 05:05:03
156	53	2006-02-15 05:05:03
156	155	2006-02-15 05:05:03
156	198	2006-02-15 05:05:03
156	244	2006-02-15 05:05:03
156	262	2006-02-15 05:05:03
156	263	2006-02-15 05:05:03
156	285	2006-02-15 05:05:03
156	297	2006-02-15 05:05:03
156	301	2006-02-15 05:05:03
156	349	2006-02-15 05:05:03
156	379	2006-02-15 05:05:03
156	448	2006-02-15 05:05:03
156	462	2006-02-15 05:05:03
156	467	2006-02-15 05:05:03
156	504	2006-02-15 05:05:03
156	518	2006-02-15 05:05:03
156	593	2006-02-15 05:05:03
156	646	2006-02-15 05:05:03
156	705	2006-02-15 05:05:03
156	754	2006-02-15 05:05:03
156	775	2006-02-15 05:05:03
156	844	2006-02-15 05:05:03
157	10	2006-02-15 05:05:03
157	24	2006-02-15 05:05:03
157	34	2006-02-15 05:05:03
157	122	2006-02-15 05:05:03
157	159	2006-02-15 05:05:03
157	183	2006-02-15 05:05:03
157	210	2006-02-15 05:05:03
157	217	2006-02-15 05:05:03
157	291	2006-02-15 05:05:03
157	303	2006-02-15 05:05:03
157	321	2006-02-15 05:05:03
157	326	2006-02-15 05:05:03
157	353	2006-02-15 05:05:03
157	400	2006-02-15 05:05:03
157	406	2006-02-15 05:05:03
157	431	2006-02-15 05:05:03
157	496	2006-02-15 05:05:03
157	535	2006-02-15 05:05:03
157	573	2006-02-15 05:05:03
157	574	2006-02-15 05:05:03
157	604	2006-02-15 05:05:03
157	616	2006-02-15 05:05:03
157	642	2006-02-15 05:05:03
157	661	2006-02-15 05:05:03
157	696	2006-02-15 05:05:03
157	713	2006-02-15 05:05:03
157	802	2006-02-15 05:05:03
157	835	2006-02-15 05:05:03
157	874	2006-02-15 05:05:03
157	913	2006-02-15 05:05:03
157	967	2006-02-15 05:05:03
157	973	2006-02-15 05:05:03
158	32	2006-02-15 05:05:03
158	47	2006-02-15 05:05:03
158	64	2006-02-15 05:05:03
158	66	2006-02-15 05:05:03
158	102	2006-02-15 05:05:03
158	121	2006-02-15 05:05:03
158	177	2006-02-15 05:05:03
158	178	2006-02-15 05:05:03
158	188	2006-02-15 05:05:03
158	215	2006-02-15 05:05:03
158	241	2006-02-15 05:05:03
158	293	2006-02-15 05:05:03
158	437	2006-02-15 05:05:03
158	473	2006-02-15 05:05:03
158	483	2006-02-15 05:05:03
158	532	2006-02-15 05:05:03
158	555	2006-02-15 05:05:03
158	581	2006-02-15 05:05:03
158	601	2006-02-15 05:05:03
158	616	2006-02-15 05:05:03
158	626	2006-02-15 05:05:03
158	637	2006-02-15 05:05:03
158	799	2006-02-15 05:05:03
158	812	2006-02-15 05:05:03
158	824	2006-02-15 05:05:03
158	830	2006-02-15 05:05:03
158	840	2006-02-15 05:05:03
158	869	2006-02-15 05:05:03
158	879	2006-02-15 05:05:03
158	880	2006-02-15 05:05:03
158	894	2006-02-15 05:05:03
158	896	2006-02-15 05:05:03
158	967	2006-02-15 05:05:03
158	968	2006-02-15 05:05:03
158	990	2006-02-15 05:05:03
159	20	2006-02-15 05:05:03
159	82	2006-02-15 05:05:03
159	127	2006-02-15 05:05:03
159	187	2006-02-15 05:05:03
159	206	2006-02-15 05:05:03
159	208	2006-02-15 05:05:03
159	223	2006-02-15 05:05:03
159	248	2006-02-15 05:05:03
159	342	2006-02-15 05:05:03
159	343	2006-02-15 05:05:03
159	344	2006-02-15 05:05:03
159	364	2006-02-15 05:05:03
159	418	2006-02-15 05:05:03
159	549	2006-02-15 05:05:03
159	561	2006-02-15 05:05:03
159	600	2006-02-15 05:05:03
159	674	2006-02-15 05:05:03
159	680	2006-02-15 05:05:03
159	784	2006-02-15 05:05:03
159	789	2006-02-15 05:05:03
159	800	2006-02-15 05:05:03
159	802	2006-02-15 05:05:03
159	818	2006-02-15 05:05:03
159	876	2006-02-15 05:05:03
159	907	2006-02-15 05:05:03
159	978	2006-02-15 05:05:03
160	2	2006-02-15 05:05:03
160	17	2006-02-15 05:05:03
160	43	2006-02-15 05:05:03
160	242	2006-02-15 05:05:03
160	267	2006-02-15 05:05:03
160	275	2006-02-15 05:05:03
160	368	2006-02-15 05:05:03
160	455	2006-02-15 05:05:03
160	469	2006-02-15 05:05:03
160	484	2006-02-15 05:05:03
160	579	2006-02-15 05:05:03
160	660	2006-02-15 05:05:03
160	755	2006-02-15 05:05:03
160	767	2006-02-15 05:05:03
160	769	2006-02-15 05:05:03
160	794	2006-02-15 05:05:03
160	826	2006-02-15 05:05:03
160	883	2006-02-15 05:05:03
160	950	2006-02-15 05:05:03
160	954	2006-02-15 05:05:03
161	43	2006-02-15 05:05:03
161	58	2006-02-15 05:05:03
161	89	2006-02-15 05:05:03
161	90	2006-02-15 05:05:03
161	120	2006-02-15 05:05:03
161	188	2006-02-15 05:05:03
161	247	2006-02-15 05:05:03
161	269	2006-02-15 05:05:03
161	281	2006-02-15 05:05:03
161	340	2006-02-15 05:05:03
161	353	2006-02-15 05:05:03
161	401	2006-02-15 05:05:03
161	414	2006-02-15 05:05:03
161	425	2006-02-15 05:05:03
161	469	2006-02-15 05:05:03
161	526	2006-02-15 05:05:03
161	588	2006-02-15 05:05:03
161	644	2006-02-15 05:05:03
161	653	2006-02-15 05:05:03
161	655	2006-02-15 05:05:03
161	669	2006-02-15 05:05:03
161	684	2006-02-15 05:05:03
161	714	2006-02-15 05:05:03
161	749	2006-02-15 05:05:03
161	807	2006-02-15 05:05:03
161	825	2006-02-15 05:05:03
161	850	2006-02-15 05:05:03
161	880	2006-02-15 05:05:03
161	920	2006-02-15 05:05:03
161	921	2006-02-15 05:05:03
161	924	2006-02-15 05:05:03
161	927	2006-02-15 05:05:03
162	1	2006-02-15 05:05:03
162	4	2006-02-15 05:05:03
162	7	2006-02-15 05:05:03
162	18	2006-02-15 05:05:03
162	28	2006-02-15 05:05:03
162	32	2006-02-15 05:05:03
162	33	2006-02-15 05:05:03
162	41	2006-02-15 05:05:03
162	85	2006-02-15 05:05:03
162	121	2006-02-15 05:05:03
162	164	2006-02-15 05:05:03
162	274	2006-02-15 05:05:03
162	279	2006-02-15 05:05:03
162	409	2006-02-15 05:05:03
162	410	2006-02-15 05:05:03
162	415	2006-02-15 05:05:03
162	500	2006-02-15 05:05:03
162	574	2006-02-15 05:05:03
162	612	2006-02-15 05:05:03
162	636	2006-02-15 05:05:03
162	659	2006-02-15 05:05:03
162	786	2006-02-15 05:05:03
162	844	2006-02-15 05:05:03
162	909	2006-02-15 05:05:03
162	968	2006-02-15 05:05:03
163	30	2006-02-15 05:05:03
163	45	2006-02-15 05:05:03
163	166	2006-02-15 05:05:03
163	180	2006-02-15 05:05:03
163	239	2006-02-15 05:05:03
163	283	2006-02-15 05:05:03
163	303	2006-02-15 05:05:03
163	304	2006-02-15 05:05:03
163	307	2006-02-15 05:05:03
163	394	2006-02-15 05:05:03
163	409	2006-02-15 05:05:03
163	434	2006-02-15 05:05:03
163	444	2006-02-15 05:05:03
163	522	2006-02-15 05:05:03
163	719	2006-02-15 05:05:03
163	785	2006-02-15 05:05:03
163	833	2006-02-15 05:05:03
163	881	2006-02-15 05:05:03
163	891	2006-02-15 05:05:03
163	947	2006-02-15 05:05:03
163	996	2006-02-15 05:05:03
164	15	2006-02-15 05:05:03
164	23	2006-02-15 05:05:03
164	148	2006-02-15 05:05:03
164	169	2006-02-15 05:05:03
164	252	2006-02-15 05:05:03
164	324	2006-02-15 05:05:03
164	347	2006-02-15 05:05:03
164	367	2006-02-15 05:05:03
164	431	2006-02-15 05:05:03
164	448	2006-02-15 05:05:03
164	469	2006-02-15 05:05:03
164	545	2006-02-15 05:05:03
164	610	2006-02-15 05:05:03
164	613	2006-02-15 05:05:03
164	673	2006-02-15 05:05:03
164	681	2006-02-15 05:05:03
164	698	2006-02-15 05:05:03
164	801	2006-02-15 05:05:03
164	820	2006-02-15 05:05:03
164	832	2006-02-15 05:05:03
164	834	2006-02-15 05:05:03
164	851	2006-02-15 05:05:03
164	884	2006-02-15 05:05:03
164	908	2006-02-15 05:05:03
164	957	2006-02-15 05:05:03
164	984	2006-02-15 05:05:03
165	72	2006-02-15 05:05:03
165	95	2006-02-15 05:05:03
165	146	2006-02-15 05:05:03
165	204	2006-02-15 05:05:03
165	253	2006-02-15 05:05:03
165	286	2006-02-15 05:05:03
165	360	2006-02-15 05:05:03
165	375	2006-02-15 05:05:03
165	395	2006-02-15 05:05:03
165	421	2006-02-15 05:05:03
165	437	2006-02-15 05:05:03
165	473	2006-02-15 05:05:03
165	607	2006-02-15 05:05:03
165	644	2006-02-15 05:05:03
165	659	2006-02-15 05:05:03
165	693	2006-02-15 05:05:03
165	737	2006-02-15 05:05:03
165	779	2006-02-15 05:05:03
165	798	2006-02-15 05:05:03
165	807	2006-02-15 05:05:03
165	809	2006-02-15 05:05:03
165	832	2006-02-15 05:05:03
165	833	2006-02-15 05:05:03
165	947	2006-02-15 05:05:03
165	948	2006-02-15 05:05:03
165	962	2006-02-15 05:05:03
166	25	2006-02-15 05:05:03
166	38	2006-02-15 05:05:03
166	55	2006-02-15 05:05:03
166	61	2006-02-15 05:05:03
166	68	2006-02-15 05:05:03
166	86	2006-02-15 05:05:03
166	146	2006-02-15 05:05:03
166	255	2006-02-15 05:05:03
166	297	2006-02-15 05:05:03
166	306	2006-02-15 05:05:03
166	326	2006-02-15 05:05:03
166	361	2006-02-15 05:05:03
166	366	2006-02-15 05:05:03
166	426	2006-02-15 05:05:03
166	580	2006-02-15 05:05:03
166	622	2006-02-15 05:05:03
166	674	2006-02-15 05:05:03
166	714	2006-02-15 05:05:03
166	788	2006-02-15 05:05:03
166	867	2006-02-15 05:05:03
166	944	2006-02-15 05:05:03
166	1000	2006-02-15 05:05:03
167	17	2006-02-15 05:05:03
167	25	2006-02-15 05:05:03
167	63	2006-02-15 05:05:03
167	72	2006-02-15 05:05:03
167	107	2006-02-15 05:05:03
167	120	2006-02-15 05:05:03
167	191	2006-02-15 05:05:03
167	294	2006-02-15 05:05:03
167	319	2006-02-15 05:05:03
167	339	2006-02-15 05:05:03
167	341	2006-02-15 05:05:03
167	496	2006-02-15 05:05:03
167	554	2006-02-15 05:05:03
167	626	2006-02-15 05:05:03
167	628	2006-02-15 05:05:03
167	672	2006-02-15 05:05:03
167	692	2006-02-15 05:05:03
167	717	2006-02-15 05:05:03
167	734	2006-02-15 05:05:03
167	794	2006-02-15 05:05:03
167	800	2006-02-15 05:05:03
167	802	2006-02-15 05:05:03
167	856	2006-02-15 05:05:03
167	864	2006-02-15 05:05:03
167	882	2006-02-15 05:05:03
167	923	2006-02-15 05:05:03
168	32	2006-02-15 05:05:03
168	56	2006-02-15 05:05:03
168	92	2006-02-15 05:05:03
168	115	2006-02-15 05:05:03
168	188	2006-02-15 05:05:03
168	196	2006-02-15 05:05:03
168	208	2006-02-15 05:05:03
168	237	2006-02-15 05:05:03
168	241	2006-02-15 05:05:03
168	255	2006-02-15 05:05:03
168	305	2006-02-15 05:05:03
168	336	2006-02-15 05:05:03
168	387	2006-02-15 05:05:03
168	433	2006-02-15 05:05:03
168	438	2006-02-15 05:05:03
168	519	2006-02-15 05:05:03
168	602	2006-02-15 05:05:03
168	619	2006-02-15 05:05:03
168	626	2006-02-15 05:05:03
168	652	2006-02-15 05:05:03
168	678	2006-02-15 05:05:03
168	685	2006-02-15 05:05:03
168	804	2006-02-15 05:05:03
168	807	2006-02-15 05:05:03
168	826	2006-02-15 05:05:03
168	841	2006-02-15 05:05:03
168	886	2006-02-15 05:05:03
168	889	2006-02-15 05:05:03
168	892	2006-02-15 05:05:03
168	927	2006-02-15 05:05:03
168	959	2006-02-15 05:05:03
169	6	2006-02-15 05:05:03
169	78	2006-02-15 05:05:03
169	93	2006-02-15 05:05:03
169	246	2006-02-15 05:05:03
169	248	2006-02-15 05:05:03
169	289	2006-02-15 05:05:03
169	301	2006-02-15 05:05:03
169	326	2006-02-15 05:05:03
169	349	2006-02-15 05:05:03
169	372	2006-02-15 05:05:03
169	398	2006-02-15 05:05:03
169	434	2006-02-15 05:05:03
169	505	2006-02-15 05:05:03
169	564	2006-02-15 05:05:03
169	571	2006-02-15 05:05:03
169	634	2006-02-15 05:05:03
169	642	2006-02-15 05:05:03
169	673	2006-02-15 05:05:03
169	694	2006-02-15 05:05:03
169	727	2006-02-15 05:05:03
169	778	2006-02-15 05:05:03
169	815	2006-02-15 05:05:03
169	847	2006-02-15 05:05:03
169	849	2006-02-15 05:05:03
169	894	2006-02-15 05:05:03
169	897	2006-02-15 05:05:03
169	954	2006-02-15 05:05:03
169	992	2006-02-15 05:05:03
169	998	2006-02-15 05:05:03
170	7	2006-02-15 05:05:03
170	15	2006-02-15 05:05:03
170	27	2006-02-15 05:05:03
170	33	2006-02-15 05:05:03
170	102	2006-02-15 05:05:03
170	139	2006-02-15 05:05:03
170	180	2006-02-15 05:05:03
170	184	2006-02-15 05:05:03
170	212	2006-02-15 05:05:03
170	299	2006-02-15 05:05:03
170	322	2006-02-15 05:05:03
170	358	2006-02-15 05:05:03
170	416	2006-02-15 05:05:03
170	508	2006-02-15 05:05:03
170	537	2006-02-15 05:05:03
170	705	2006-02-15 05:05:03
170	758	2006-02-15 05:05:03
170	764	2006-02-15 05:05:03
170	868	2006-02-15 05:05:03
170	877	2006-02-15 05:05:03
170	886	2006-02-15 05:05:03
170	925	2006-02-15 05:05:03
170	993	2006-02-15 05:05:03
170	996	2006-02-15 05:05:03
171	49	2006-02-15 05:05:03
171	146	2006-02-15 05:05:03
171	166	2006-02-15 05:05:03
171	181	2006-02-15 05:05:03
171	219	2006-02-15 05:05:03
171	273	2006-02-15 05:05:03
171	296	2006-02-15 05:05:03
171	318	2006-02-15 05:05:03
171	342	2006-02-15 05:05:03
171	397	2006-02-15 05:05:03
171	447	2006-02-15 05:05:03
171	450	2006-02-15 05:05:03
171	466	2006-02-15 05:05:03
171	549	2006-02-15 05:05:03
171	560	2006-02-15 05:05:03
171	566	2006-02-15 05:05:03
171	608	2006-02-15 05:05:03
171	625	2006-02-15 05:05:03
171	645	2006-02-15 05:05:03
171	701	2006-02-15 05:05:03
171	761	2006-02-15 05:05:03
171	779	2006-02-15 05:05:03
171	849	2006-02-15 05:05:03
171	872	2006-02-15 05:05:03
171	892	2006-02-15 05:05:03
171	898	2006-02-15 05:05:03
171	903	2006-02-15 05:05:03
171	953	2006-02-15 05:05:03
172	57	2006-02-15 05:05:03
172	100	2006-02-15 05:05:03
172	148	2006-02-15 05:05:03
172	215	2006-02-15 05:05:03
172	302	2006-02-15 05:05:03
172	345	2006-02-15 05:05:03
172	368	2006-02-15 05:05:03
172	385	2006-02-15 05:05:03
172	423	2006-02-15 05:05:03
172	487	2006-02-15 05:05:03
172	493	2006-02-15 05:05:03
172	529	2006-02-15 05:05:03
172	538	2006-02-15 05:05:03
172	567	2006-02-15 05:05:03
172	609	2006-02-15 05:05:03
172	639	2006-02-15 05:05:03
172	649	2006-02-15 05:05:03
172	661	2006-02-15 05:05:03
172	667	2006-02-15 05:05:03
172	710	2006-02-15 05:05:03
172	744	2006-02-15 05:05:03
172	758	2006-02-15 05:05:03
172	771	2006-02-15 05:05:03
172	833	2006-02-15 05:05:03
172	959	2006-02-15 05:05:03
173	49	2006-02-15 05:05:03
173	55	2006-02-15 05:05:03
173	74	2006-02-15 05:05:03
173	80	2006-02-15 05:05:03
173	106	2006-02-15 05:05:03
173	154	2006-02-15 05:05:03
173	162	2006-02-15 05:05:03
173	188	2006-02-15 05:05:03
173	235	2006-02-15 05:05:03
173	313	2006-02-15 05:05:03
173	379	2006-02-15 05:05:03
173	405	2006-02-15 05:05:03
173	491	2006-02-15 05:05:03
173	496	2006-02-15 05:05:03
173	529	2006-02-15 05:05:03
173	550	2006-02-15 05:05:03
173	564	2006-02-15 05:05:03
173	571	2006-02-15 05:05:03
173	592	2006-02-15 05:05:03
173	688	2006-02-15 05:05:03
173	753	2006-02-15 05:05:03
173	757	2006-02-15 05:05:03
173	852	2006-02-15 05:05:03
173	857	2006-02-15 05:05:03
173	921	2006-02-15 05:05:03
173	928	2006-02-15 05:05:03
173	933	2006-02-15 05:05:03
174	11	2006-02-15 05:05:03
174	61	2006-02-15 05:05:03
174	168	2006-02-15 05:05:03
174	298	2006-02-15 05:05:03
174	352	2006-02-15 05:05:03
174	442	2006-02-15 05:05:03
174	451	2006-02-15 05:05:03
174	496	2006-02-15 05:05:03
174	610	2006-02-15 05:05:03
174	618	2006-02-15 05:05:03
174	622	2006-02-15 05:05:03
174	659	2006-02-15 05:05:03
174	677	2006-02-15 05:05:03
174	705	2006-02-15 05:05:03
174	722	2006-02-15 05:05:03
174	780	2006-02-15 05:05:03
174	797	2006-02-15 05:05:03
174	809	2006-02-15 05:05:03
174	827	2006-02-15 05:05:03
174	830	2006-02-15 05:05:03
174	852	2006-02-15 05:05:03
174	853	2006-02-15 05:05:03
174	879	2006-02-15 05:05:03
174	982	2006-02-15 05:05:03
175	9	2006-02-15 05:05:03
175	29	2006-02-15 05:05:03
175	67	2006-02-15 05:05:03
175	129	2006-02-15 05:05:03
175	155	2006-02-15 05:05:03
175	190	2006-02-15 05:05:03
175	191	2006-02-15 05:05:03
175	362	2006-02-15 05:05:03
175	405	2006-02-15 05:05:03
175	424	2006-02-15 05:05:03
175	439	2006-02-15 05:05:03
175	442	2006-02-15 05:05:03
175	483	2006-02-15 05:05:03
175	591	2006-02-15 05:05:03
175	596	2006-02-15 05:05:03
175	616	2006-02-15 05:05:03
175	719	2006-02-15 05:05:03
175	729	2006-02-15 05:05:03
175	772	2006-02-15 05:05:03
175	778	2006-02-15 05:05:03
175	828	2006-02-15 05:05:03
175	842	2006-02-15 05:05:03
175	890	2006-02-15 05:05:03
175	908	2006-02-15 05:05:03
175	977	2006-02-15 05:05:03
175	978	2006-02-15 05:05:03
175	998	2006-02-15 05:05:03
176	13	2006-02-15 05:05:03
176	73	2006-02-15 05:05:03
176	89	2006-02-15 05:05:03
176	150	2006-02-15 05:05:03
176	162	2006-02-15 05:05:03
176	238	2006-02-15 05:05:03
176	252	2006-02-15 05:05:03
176	303	2006-02-15 05:05:03
176	320	2006-02-15 05:05:03
176	401	2006-02-15 05:05:03
176	417	2006-02-15 05:05:03
176	441	2006-02-15 05:05:03
176	458	2006-02-15 05:05:03
176	461	2006-02-15 05:05:03
176	517	2006-02-15 05:05:03
176	521	2006-02-15 05:05:03
176	543	2006-02-15 05:05:03
176	573	2006-02-15 05:05:03
176	699	2006-02-15 05:05:03
176	726	2006-02-15 05:05:03
176	740	2006-02-15 05:05:03
176	746	2006-02-15 05:05:03
176	758	2006-02-15 05:05:03
176	802	2006-02-15 05:05:03
176	827	2006-02-15 05:05:03
176	839	2006-02-15 05:05:03
176	859	2006-02-15 05:05:03
176	872	2006-02-15 05:05:03
176	946	2006-02-15 05:05:03
177	12	2006-02-15 05:05:03
177	39	2006-02-15 05:05:03
177	52	2006-02-15 05:05:03
177	55	2006-02-15 05:05:03
177	86	2006-02-15 05:05:03
177	175	2006-02-15 05:05:03
177	188	2006-02-15 05:05:03
177	235	2006-02-15 05:05:03
177	237	2006-02-15 05:05:03
177	289	2006-02-15 05:05:03
177	363	2006-02-15 05:05:03
177	401	2006-02-15 05:05:03
177	433	2006-02-15 05:05:03
177	458	2006-02-15 05:05:03
177	522	2006-02-15 05:05:03
177	543	2006-02-15 05:05:03
177	563	2006-02-15 05:05:03
177	649	2006-02-15 05:05:03
177	683	2006-02-15 05:05:03
177	684	2006-02-15 05:05:03
177	726	2006-02-15 05:05:03
177	751	2006-02-15 05:05:03
177	763	2006-02-15 05:05:03
177	764	2006-02-15 05:05:03
177	827	2006-02-15 05:05:03
177	910	2006-02-15 05:05:03
177	956	2006-02-15 05:05:03
178	30	2006-02-15 05:05:03
178	34	2006-02-15 05:05:03
178	109	2006-02-15 05:05:03
178	146	2006-02-15 05:05:03
178	160	2006-02-15 05:05:03
178	164	2006-02-15 05:05:03
178	194	2006-02-15 05:05:03
178	197	2006-02-15 05:05:03
178	273	2006-02-15 05:05:03
178	311	2006-02-15 05:05:03
178	397	2006-02-15 05:05:03
178	483	2006-02-15 05:05:03
178	517	2006-02-15 05:05:03
178	537	2006-02-15 05:05:03
178	587	2006-02-15 05:05:03
178	708	2006-02-15 05:05:03
178	733	2006-02-15 05:05:03
178	744	2006-02-15 05:05:03
178	762	2006-02-15 05:05:03
178	930	2006-02-15 05:05:03
178	974	2006-02-15 05:05:03
178	983	2006-02-15 05:05:03
178	1000	2006-02-15 05:05:03
179	24	2006-02-15 05:05:03
179	27	2006-02-15 05:05:03
179	65	2006-02-15 05:05:03
179	85	2006-02-15 05:05:03
179	109	2006-02-15 05:05:03
179	131	2006-02-15 05:05:03
179	159	2006-02-15 05:05:03
179	193	2006-02-15 05:05:03
179	250	2006-02-15 05:05:03
179	291	2006-02-15 05:05:03
179	353	2006-02-15 05:05:03
179	415	2006-02-15 05:05:03
179	463	2006-02-15 05:05:03
179	468	2006-02-15 05:05:03
179	489	2006-02-15 05:05:03
179	566	2006-02-15 05:05:03
179	588	2006-02-15 05:05:03
179	650	2006-02-15 05:05:03
179	698	2006-02-15 05:05:03
179	732	2006-02-15 05:05:03
179	737	2006-02-15 05:05:03
179	769	2006-02-15 05:05:03
179	811	2006-02-15 05:05:03
179	817	2006-02-15 05:05:03
179	852	2006-02-15 05:05:03
179	924	2006-02-15 05:05:03
179	931	2006-02-15 05:05:03
179	960	2006-02-15 05:05:03
179	976	2006-02-15 05:05:03
180	12	2006-02-15 05:05:03
180	33	2006-02-15 05:05:03
180	144	2006-02-15 05:05:03
180	195	2006-02-15 05:05:03
180	258	2006-02-15 05:05:03
180	441	2006-02-15 05:05:03
180	506	2006-02-15 05:05:03
180	561	2006-02-15 05:05:03
180	609	2006-02-15 05:05:03
180	622	2006-02-15 05:05:03
180	628	2006-02-15 05:05:03
180	657	2006-02-15 05:05:03
180	724	2006-02-15 05:05:03
180	729	2006-02-15 05:05:03
180	732	2006-02-15 05:05:03
180	777	2006-02-15 05:05:03
180	809	2006-02-15 05:05:03
180	811	2006-02-15 05:05:03
180	820	2006-02-15 05:05:03
180	824	2006-02-15 05:05:03
180	847	2006-02-15 05:05:03
180	869	2006-02-15 05:05:03
180	874	2006-02-15 05:05:03
180	955	2006-02-15 05:05:03
180	963	2006-02-15 05:05:03
181	5	2006-02-15 05:05:03
181	40	2006-02-15 05:05:03
181	74	2006-02-15 05:05:03
181	78	2006-02-15 05:05:03
181	83	2006-02-15 05:05:03
181	152	2006-02-15 05:05:03
181	195	2006-02-15 05:05:03
181	233	2006-02-15 05:05:03
181	286	2006-02-15 05:05:03
181	301	2006-02-15 05:05:03
181	311	2006-02-15 05:05:03
181	381	2006-02-15 05:05:03
181	387	2006-02-15 05:05:03
181	403	2006-02-15 05:05:03
181	409	2006-02-15 05:05:03
181	420	2006-02-15 05:05:03
181	437	2006-02-15 05:05:03
181	456	2006-02-15 05:05:03
181	507	2006-02-15 05:05:03
181	522	2006-02-15 05:05:03
181	539	2006-02-15 05:05:03
181	542	2006-02-15 05:05:03
181	546	2006-02-15 05:05:03
181	579	2006-02-15 05:05:03
181	596	2006-02-15 05:05:03
181	604	2006-02-15 05:05:03
181	609	2006-02-15 05:05:03
181	625	2006-02-15 05:05:03
181	744	2006-02-15 05:05:03
181	816	2006-02-15 05:05:03
181	836	2006-02-15 05:05:03
181	868	2006-02-15 05:05:03
181	870	2006-02-15 05:05:03
181	874	2006-02-15 05:05:03
181	892	2006-02-15 05:05:03
181	907	2006-02-15 05:05:03
181	911	2006-02-15 05:05:03
181	921	2006-02-15 05:05:03
181	991	2006-02-15 05:05:03
182	33	2006-02-15 05:05:03
182	160	2006-02-15 05:05:03
182	301	2006-02-15 05:05:03
182	324	2006-02-15 05:05:03
182	346	2006-02-15 05:05:03
182	362	2006-02-15 05:05:03
182	391	2006-02-15 05:05:03
182	413	2006-02-15 05:05:03
182	421	2006-02-15 05:05:03
182	437	2006-02-15 05:05:03
182	590	2006-02-15 05:05:03
182	639	2006-02-15 05:05:03
182	668	2006-02-15 05:05:03
182	677	2006-02-15 05:05:03
182	679	2006-02-15 05:05:03
182	695	2006-02-15 05:05:03
182	714	2006-02-15 05:05:03
182	720	2006-02-15 05:05:03
182	819	2006-02-15 05:05:03
182	828	2006-02-15 05:05:03
182	845	2006-02-15 05:05:03
182	864	2006-02-15 05:05:03
182	940	2006-02-15 05:05:03
182	990	2006-02-15 05:05:03
183	32	2006-02-15 05:05:03
183	40	2006-02-15 05:05:03
183	71	2006-02-15 05:05:03
183	113	2006-02-15 05:05:03
183	313	2006-02-15 05:05:03
183	388	2006-02-15 05:05:03
183	389	2006-02-15 05:05:03
183	390	2006-02-15 05:05:03
183	495	2006-02-15 05:05:03
183	520	2006-02-15 05:05:03
183	576	2006-02-15 05:05:03
183	636	2006-02-15 05:05:03
183	715	2006-02-15 05:05:03
183	850	2006-02-15 05:05:03
183	862	2006-02-15 05:05:03
183	914	2006-02-15 05:05:03
183	941	2006-02-15 05:05:03
183	949	2006-02-15 05:05:03
183	983	2006-02-15 05:05:03
184	35	2006-02-15 05:05:03
184	87	2006-02-15 05:05:03
184	146	2006-02-15 05:05:03
184	169	2006-02-15 05:05:03
184	221	2006-02-15 05:05:03
184	336	2006-02-15 05:05:03
184	371	2006-02-15 05:05:03
184	452	2006-02-15 05:05:03
184	486	2006-02-15 05:05:03
184	492	2006-02-15 05:05:03
184	500	2006-02-15 05:05:03
184	574	2006-02-15 05:05:03
184	580	2006-02-15 05:05:03
184	597	2006-02-15 05:05:03
184	615	2006-02-15 05:05:03
184	640	2006-02-15 05:05:03
184	642	2006-02-15 05:05:03
184	650	2006-02-15 05:05:03
184	661	2006-02-15 05:05:03
184	684	2006-02-15 05:05:03
184	745	2006-02-15 05:05:03
184	772	2006-02-15 05:05:03
184	787	2006-02-15 05:05:03
184	867	2006-02-15 05:05:03
184	959	2006-02-15 05:05:03
184	966	2006-02-15 05:05:03
184	967	2006-02-15 05:05:03
184	969	2006-02-15 05:05:03
184	985	2006-02-15 05:05:03
185	7	2006-02-15 05:05:03
185	95	2006-02-15 05:05:03
185	138	2006-02-15 05:05:03
185	265	2006-02-15 05:05:03
185	286	2006-02-15 05:05:03
185	360	2006-02-15 05:05:03
185	411	2006-02-15 05:05:03
185	427	2006-02-15 05:05:03
185	437	2006-02-15 05:05:03
185	448	2006-02-15 05:05:03
185	494	2006-02-15 05:05:03
185	510	2006-02-15 05:05:03
185	518	2006-02-15 05:05:03
185	554	2006-02-15 05:05:03
185	560	2006-02-15 05:05:03
185	571	2006-02-15 05:05:03
185	584	2006-02-15 05:05:03
185	631	2006-02-15 05:05:03
185	665	2006-02-15 05:05:03
185	694	2006-02-15 05:05:03
185	730	2006-02-15 05:05:03
185	761	2006-02-15 05:05:03
185	818	2006-02-15 05:05:03
185	845	2006-02-15 05:05:03
185	880	2006-02-15 05:05:03
185	882	2006-02-15 05:05:03
185	919	2006-02-15 05:05:03
185	920	2006-02-15 05:05:03
185	965	2006-02-15 05:05:03
185	973	2006-02-15 05:05:03
186	95	2006-02-15 05:05:03
186	187	2006-02-15 05:05:03
186	208	2006-02-15 05:05:03
186	228	2006-02-15 05:05:03
186	237	2006-02-15 05:05:03
186	422	2006-02-15 05:05:03
186	482	2006-02-15 05:05:03
186	508	2006-02-15 05:05:03
186	552	2006-02-15 05:05:03
186	579	2006-02-15 05:05:03
186	637	2006-02-15 05:05:03
186	648	2006-02-15 05:05:03
186	654	2006-02-15 05:05:03
186	729	2006-02-15 05:05:03
186	983	2006-02-15 05:05:03
186	994	2006-02-15 05:05:03
187	17	2006-02-15 05:05:03
187	25	2006-02-15 05:05:03
187	29	2006-02-15 05:05:03
187	51	2006-02-15 05:05:03
187	73	2006-02-15 05:05:03
187	76	2006-02-15 05:05:03
187	98	2006-02-15 05:05:03
187	110	2006-02-15 05:05:03
187	127	2006-02-15 05:05:03
187	168	2006-02-15 05:05:03
187	222	2006-02-15 05:05:03
187	224	2006-02-15 05:05:03
187	297	2006-02-15 05:05:03
187	354	2006-02-15 05:05:03
187	379	2006-02-15 05:05:03
187	417	2006-02-15 05:05:03
187	435	2006-02-15 05:05:03
187	441	2006-02-15 05:05:03
187	474	2006-02-15 05:05:03
187	499	2006-02-15 05:05:03
187	538	2006-02-15 05:05:03
187	548	2006-02-15 05:05:03
187	561	2006-02-15 05:05:03
187	617	2006-02-15 05:05:03
187	625	2006-02-15 05:05:03
187	664	2006-02-15 05:05:03
187	671	2006-02-15 05:05:03
187	768	2006-02-15 05:05:03
187	779	2006-02-15 05:05:03
187	906	2006-02-15 05:05:03
187	914	2006-02-15 05:05:03
187	923	2006-02-15 05:05:03
187	976	2006-02-15 05:05:03
188	1	2006-02-15 05:05:03
188	10	2006-02-15 05:05:03
188	14	2006-02-15 05:05:03
188	51	2006-02-15 05:05:03
188	102	2006-02-15 05:05:03
188	111	2006-02-15 05:05:03
188	146	2006-02-15 05:05:03
188	206	2006-02-15 05:05:03
188	223	2006-02-15 05:05:03
188	289	2006-02-15 05:05:03
188	311	2006-02-15 05:05:03
188	322	2006-02-15 05:05:03
188	338	2006-02-15 05:05:03
188	396	2006-02-15 05:05:03
188	412	2006-02-15 05:05:03
188	506	2006-02-15 05:05:03
188	517	2006-02-15 05:05:03
188	529	2006-02-15 05:05:03
188	566	2006-02-15 05:05:03
188	593	2006-02-15 05:05:03
188	606	2006-02-15 05:05:03
188	662	2006-02-15 05:05:03
188	770	2006-02-15 05:05:03
188	773	2006-02-15 05:05:03
188	774	2006-02-15 05:05:03
188	815	2006-02-15 05:05:03
188	849	2006-02-15 05:05:03
188	925	2006-02-15 05:05:03
188	988	2006-02-15 05:05:03
188	989	2006-02-15 05:05:03
189	43	2006-02-15 05:05:03
189	82	2006-02-15 05:05:03
189	171	2006-02-15 05:05:03
189	266	2006-02-15 05:05:03
189	272	2006-02-15 05:05:03
189	315	2006-02-15 05:05:03
189	378	2006-02-15 05:05:03
189	492	2006-02-15 05:05:03
189	509	2006-02-15 05:05:03
189	512	2006-02-15 05:05:03
189	519	2006-02-15 05:05:03
189	533	2006-02-15 05:05:03
189	548	2006-02-15 05:05:03
189	560	2006-02-15 05:05:03
189	628	2006-02-15 05:05:03
189	734	2006-02-15 05:05:03
189	748	2006-02-15 05:05:03
189	788	2006-02-15 05:05:03
189	820	2006-02-15 05:05:03
189	853	2006-02-15 05:05:03
189	882	2006-02-15 05:05:03
189	896	2006-02-15 05:05:03
189	899	2006-02-15 05:05:03
189	940	2006-02-15 05:05:03
190	38	2006-02-15 05:05:03
190	54	2006-02-15 05:05:03
190	62	2006-02-15 05:05:03
190	87	2006-02-15 05:05:03
190	173	2006-02-15 05:05:03
190	234	2006-02-15 05:05:03
190	253	2006-02-15 05:05:03
190	278	2006-02-15 05:05:03
190	310	2006-02-15 05:05:03
190	374	2006-02-15 05:05:03
190	411	2006-02-15 05:05:03
190	426	2006-02-15 05:05:03
190	472	2006-02-15 05:05:03
190	549	2006-02-15 05:05:03
190	562	2006-02-15 05:05:03
190	606	2006-02-15 05:05:03
190	623	2006-02-15 05:05:03
190	679	2006-02-15 05:05:03
190	682	2006-02-15 05:05:03
190	693	2006-02-15 05:05:03
190	695	2006-02-15 05:05:03
190	705	2006-02-15 05:05:03
190	708	2006-02-15 05:05:03
190	802	2006-02-15 05:05:03
190	806	2006-02-15 05:05:03
190	874	2006-02-15 05:05:03
190	959	2006-02-15 05:05:03
191	16	2006-02-15 05:05:03
191	39	2006-02-15 05:05:03
191	84	2006-02-15 05:05:03
191	185	2006-02-15 05:05:03
191	219	2006-02-15 05:05:03
191	293	2006-02-15 05:05:03
191	296	2006-02-15 05:05:03
191	378	2006-02-15 05:05:03
191	410	2006-02-15 05:05:03
191	420	2006-02-15 05:05:03
191	461	2006-02-15 05:05:03
191	544	2006-02-15 05:05:03
191	551	2006-02-15 05:05:03
191	596	2006-02-15 05:05:03
191	638	2006-02-15 05:05:03
191	668	2006-02-15 05:05:03
191	692	2006-02-15 05:05:03
191	775	2006-02-15 05:05:03
191	801	2006-02-15 05:05:03
191	819	2006-02-15 05:05:03
191	827	2006-02-15 05:05:03
191	830	2006-02-15 05:05:03
191	834	2006-02-15 05:05:03
191	849	2006-02-15 05:05:03
191	858	2006-02-15 05:05:03
191	914	2006-02-15 05:05:03
191	958	2006-02-15 05:05:03
191	969	2006-02-15 05:05:03
191	971	2006-02-15 05:05:03
191	993	2006-02-15 05:05:03
192	16	2006-02-15 05:05:03
192	69	2006-02-15 05:05:03
192	117	2006-02-15 05:05:03
192	155	2006-02-15 05:05:03
192	166	2006-02-15 05:05:03
192	179	2006-02-15 05:05:03
192	214	2006-02-15 05:05:03
192	361	2006-02-15 05:05:03
192	367	2006-02-15 05:05:03
192	426	2006-02-15 05:05:03
192	465	2006-02-15 05:05:03
192	470	2006-02-15 05:05:03
192	475	2006-02-15 05:05:03
192	485	2006-02-15 05:05:03
192	541	2006-02-15 05:05:03
192	578	2006-02-15 05:05:03
192	592	2006-02-15 05:05:03
192	614	2006-02-15 05:05:03
192	618	2006-02-15 05:05:03
192	622	2006-02-15 05:05:03
192	674	2006-02-15 05:05:03
192	677	2006-02-15 05:05:03
192	680	2006-02-15 05:05:03
192	682	2006-02-15 05:05:03
192	708	2006-02-15 05:05:03
192	711	2006-02-15 05:05:03
192	747	2006-02-15 05:05:03
192	763	2006-02-15 05:05:03
192	819	2006-02-15 05:05:03
193	44	2006-02-15 05:05:03
193	80	2006-02-15 05:05:03
193	103	2006-02-15 05:05:03
193	109	2006-02-15 05:05:03
193	119	2006-02-15 05:05:03
193	141	2006-02-15 05:05:03
193	164	2006-02-15 05:05:03
193	291	2006-02-15 05:05:03
193	352	2006-02-15 05:05:03
193	358	2006-02-15 05:05:03
193	376	2006-02-15 05:05:03
193	412	2006-02-15 05:05:03
193	462	2006-02-15 05:05:03
193	689	2006-02-15 05:05:03
193	709	2006-02-15 05:05:03
193	745	2006-02-15 05:05:03
193	807	2006-02-15 05:05:03
193	828	2006-02-15 05:05:03
193	834	2006-02-15 05:05:03
193	851	2006-02-15 05:05:03
193	937	2006-02-15 05:05:03
193	953	2006-02-15 05:05:03
193	960	2006-02-15 05:05:03
194	9	2006-02-15 05:05:03
194	42	2006-02-15 05:05:03
194	67	2006-02-15 05:05:03
194	86	2006-02-15 05:05:03
194	88	2006-02-15 05:05:03
194	98	2006-02-15 05:05:03
194	135	2006-02-15 05:05:03
194	161	2006-02-15 05:05:03
194	163	2006-02-15 05:05:03
194	215	2006-02-15 05:05:03
194	232	2006-02-15 05:05:03
194	352	2006-02-15 05:05:03
194	415	2006-02-15 05:05:03
194	486	2006-02-15 05:05:03
194	498	2006-02-15 05:05:03
194	531	2006-02-15 05:05:03
194	719	2006-02-15 05:05:03
194	738	2006-02-15 05:05:03
194	786	2006-02-15 05:05:03
194	872	2006-02-15 05:05:03
194	938	2006-02-15 05:05:03
194	940	2006-02-15 05:05:03
195	129	2006-02-15 05:05:03
195	130	2006-02-15 05:05:03
195	141	2006-02-15 05:05:03
195	144	2006-02-15 05:05:03
195	298	2006-02-15 05:05:03
195	359	2006-02-15 05:05:03
195	361	2006-02-15 05:05:03
195	392	2006-02-15 05:05:03
195	403	2006-02-15 05:05:03
195	494	2006-02-15 05:05:03
195	520	2006-02-15 05:05:03
195	534	2006-02-15 05:05:03
195	560	2006-02-15 05:05:03
195	592	2006-02-15 05:05:03
195	649	2006-02-15 05:05:03
195	658	2006-02-15 05:05:03
195	673	2006-02-15 05:05:03
195	677	2006-02-15 05:05:03
195	706	2006-02-15 05:05:03
195	738	2006-02-15 05:05:03
195	769	2006-02-15 05:05:03
195	781	2006-02-15 05:05:03
195	794	2006-02-15 05:05:03
195	813	2006-02-15 05:05:03
195	869	2006-02-15 05:05:03
195	885	2006-02-15 05:05:03
195	962	2006-02-15 05:05:03
196	64	2006-02-15 05:05:03
196	122	2006-02-15 05:05:03
196	156	2006-02-15 05:05:03
196	169	2006-02-15 05:05:03
196	276	2006-02-15 05:05:03
196	284	2006-02-15 05:05:03
196	303	2006-02-15 05:05:03
196	324	2006-02-15 05:05:03
196	423	2006-02-15 05:05:03
196	473	2006-02-15 05:05:03
196	484	2006-02-15 05:05:03
196	515	2006-02-15 05:05:03
196	524	2006-02-15 05:05:03
196	541	2006-02-15 05:05:03
196	560	2006-02-15 05:05:03
196	575	2006-02-15 05:05:03
196	576	2006-02-15 05:05:03
196	587	2006-02-15 05:05:03
196	615	2006-02-15 05:05:03
196	635	2006-02-15 05:05:03
196	684	2006-02-15 05:05:03
196	795	2006-02-15 05:05:03
196	815	2006-02-15 05:05:03
196	833	2006-02-15 05:05:03
196	837	2006-02-15 05:05:03
196	906	2006-02-15 05:05:03
196	908	2006-02-15 05:05:03
196	919	2006-02-15 05:05:03
196	939	2006-02-15 05:05:03
196	972	2006-02-15 05:05:03
197	6	2006-02-15 05:05:03
197	29	2006-02-15 05:05:03
197	63	2006-02-15 05:05:03
197	123	2006-02-15 05:05:03
197	129	2006-02-15 05:05:03
197	147	2006-02-15 05:05:03
197	164	2006-02-15 05:05:03
197	189	2006-02-15 05:05:03
197	243	2006-02-15 05:05:03
197	249	2006-02-15 05:05:03
197	258	2006-02-15 05:05:03
197	364	2006-02-15 05:05:03
197	369	2006-02-15 05:05:03
197	370	2006-02-15 05:05:03
197	418	2006-02-15 05:05:03
197	522	2006-02-15 05:05:03
197	531	2006-02-15 05:05:03
197	554	2006-02-15 05:05:03
197	598	2006-02-15 05:05:03
197	628	2006-02-15 05:05:03
197	691	2006-02-15 05:05:03
197	724	2006-02-15 05:05:03
197	746	2006-02-15 05:05:03
197	752	2006-02-15 05:05:03
197	758	2006-02-15 05:05:03
197	769	2006-02-15 05:05:03
197	815	2006-02-15 05:05:03
197	916	2006-02-15 05:05:03
197	950	2006-02-15 05:05:03
197	967	2006-02-15 05:05:03
197	974	2006-02-15 05:05:03
197	979	2006-02-15 05:05:03
197	995	2006-02-15 05:05:03
198	1	2006-02-15 05:05:03
198	109	2006-02-15 05:05:03
198	125	2006-02-15 05:05:03
198	186	2006-02-15 05:05:03
198	262	2006-02-15 05:05:03
198	264	2006-02-15 05:05:03
198	303	2006-02-15 05:05:03
198	309	2006-02-15 05:05:03
198	311	2006-02-15 05:05:03
198	329	2006-02-15 05:05:03
198	347	2006-02-15 05:05:03
198	379	2006-02-15 05:05:03
198	395	2006-02-15 05:05:03
198	406	2006-02-15 05:05:03
198	450	2006-02-15 05:05:03
198	464	2006-02-15 05:05:03
198	482	2006-02-15 05:05:03
198	499	2006-02-15 05:05:03
198	536	2006-02-15 05:05:03
198	541	2006-02-15 05:05:03
198	545	2006-02-15 05:05:03
198	555	2006-02-15 05:05:03
198	568	2006-02-15 05:05:03
198	570	2006-02-15 05:05:03
198	588	2006-02-15 05:05:03
198	597	2006-02-15 05:05:03
198	628	2006-02-15 05:05:03
198	745	2006-02-15 05:05:03
198	758	2006-02-15 05:05:03
198	796	2006-02-15 05:05:03
198	806	2006-02-15 05:05:03
198	817	2006-02-15 05:05:03
198	843	2006-02-15 05:05:03
198	858	2006-02-15 05:05:03
198	871	2006-02-15 05:05:03
198	886	2006-02-15 05:05:03
198	892	2006-02-15 05:05:03
198	924	2006-02-15 05:05:03
198	952	2006-02-15 05:05:03
198	997	2006-02-15 05:05:03
199	67	2006-02-15 05:05:03
199	84	2006-02-15 05:05:03
199	145	2006-02-15 05:05:03
199	159	2006-02-15 05:05:03
199	216	2006-02-15 05:05:03
199	432	2006-02-15 05:05:03
199	541	2006-02-15 05:05:03
199	604	2006-02-15 05:05:03
199	640	2006-02-15 05:05:03
199	689	2006-02-15 05:05:03
199	730	2006-02-15 05:05:03
199	784	2006-02-15 05:05:03
199	785	2006-02-15 05:05:03
199	886	2006-02-15 05:05:03
199	953	2006-02-15 05:05:03
200	5	2006-02-15 05:05:03
200	49	2006-02-15 05:05:03
200	80	2006-02-15 05:05:03
200	116	2006-02-15 05:05:03
200	121	2006-02-15 05:05:03
200	149	2006-02-15 05:05:03
200	346	2006-02-15 05:05:03
200	419	2006-02-15 05:05:03
200	462	2006-02-15 05:05:03
200	465	2006-02-15 05:05:03
200	474	2006-02-15 05:05:03
200	537	2006-02-15 05:05:03
200	538	2006-02-15 05:05:03
200	544	2006-02-15 05:05:03
200	714	2006-02-15 05:05:03
200	879	2006-02-15 05:05:03
200	912	2006-02-15 05:05:03
200	945	2006-02-15 05:05:03
200	958	2006-02-15 05:05:03
200	993	2006-02-15 05:05:03
\.


--
-- Data for Name: film_category; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.film_category (film_id, category_id, last_update) FROM stdin;
1	6	2006-02-15 05:07:09
2	11	2006-02-15 05:07:09
3	6	2006-02-15 05:07:09
4	11	2006-02-15 05:07:09
5	8	2006-02-15 05:07:09
6	9	2006-02-15 05:07:09
7	5	2006-02-15 05:07:09
8	11	2006-02-15 05:07:09
9	11	2006-02-15 05:07:09
10	15	2006-02-15 05:07:09
11	9	2006-02-15 05:07:09
12	12	2006-02-15 05:07:09
13	11	2006-02-15 05:07:09
14	4	2006-02-15 05:07:09
15	9	2006-02-15 05:07:09
16	9	2006-02-15 05:07:09
17	12	2006-02-15 05:07:09
18	2	2006-02-15 05:07:09
19	1	2006-02-15 05:07:09
20	12	2006-02-15 05:07:09
21	1	2006-02-15 05:07:09
22	13	2006-02-15 05:07:09
23	2	2006-02-15 05:07:09
24	11	2006-02-15 05:07:09
25	13	2006-02-15 05:07:09
26	14	2006-02-15 05:07:09
27	15	2006-02-15 05:07:09
28	5	2006-02-15 05:07:09
29	1	2006-02-15 05:07:09
30	11	2006-02-15 05:07:09
31	8	2006-02-15 05:07:09
32	13	2006-02-15 05:07:09
33	7	2006-02-15 05:07:09
34	11	2006-02-15 05:07:09
35	11	2006-02-15 05:07:09
36	2	2006-02-15 05:07:09
37	4	2006-02-15 05:07:09
38	1	2006-02-15 05:07:09
39	14	2006-02-15 05:07:09
40	6	2006-02-15 05:07:09
41	16	2006-02-15 05:07:09
42	15	2006-02-15 05:07:09
43	8	2006-02-15 05:07:09
44	14	2006-02-15 05:07:09
45	13	2006-02-15 05:07:09
46	10	2006-02-15 05:07:09
47	9	2006-02-15 05:07:09
48	3	2006-02-15 05:07:09
49	14	2006-02-15 05:07:09
50	8	2006-02-15 05:07:09
51	12	2006-02-15 05:07:09
52	9	2006-02-15 05:07:09
53	8	2006-02-15 05:07:09
54	12	2006-02-15 05:07:09
55	14	2006-02-15 05:07:09
56	1	2006-02-15 05:07:09
57	16	2006-02-15 05:07:09
58	6	2006-02-15 05:07:09
59	3	2006-02-15 05:07:09
60	4	2006-02-15 05:07:09
61	7	2006-02-15 05:07:09
62	6	2006-02-15 05:07:09
63	8	2006-02-15 05:07:09
64	7	2006-02-15 05:07:09
65	11	2006-02-15 05:07:09
66	3	2006-02-15 05:07:09
67	1	2006-02-15 05:07:09
68	3	2006-02-15 05:07:09
69	14	2006-02-15 05:07:09
70	2	2006-02-15 05:07:09
71	8	2006-02-15 05:07:09
72	6	2006-02-15 05:07:09
73	14	2006-02-15 05:07:09
74	12	2006-02-15 05:07:09
75	16	2006-02-15 05:07:09
76	12	2006-02-15 05:07:09
77	13	2006-02-15 05:07:09
78	2	2006-02-15 05:07:09
79	7	2006-02-15 05:07:09
80	8	2006-02-15 05:07:09
81	14	2006-02-15 05:07:09
82	8	2006-02-15 05:07:09
83	8	2006-02-15 05:07:09
84	16	2006-02-15 05:07:09
85	6	2006-02-15 05:07:09
86	12	2006-02-15 05:07:09
87	16	2006-02-15 05:07:09
88	16	2006-02-15 05:07:09
89	2	2006-02-15 05:07:09
90	13	2006-02-15 05:07:09
91	4	2006-02-15 05:07:09
92	11	2006-02-15 05:07:09
93	13	2006-02-15 05:07:09
94	8	2006-02-15 05:07:09
95	13	2006-02-15 05:07:09
96	13	2006-02-15 05:07:09
97	1	2006-02-15 05:07:09
98	7	2006-02-15 05:07:09
99	5	2006-02-15 05:07:09
100	9	2006-02-15 05:07:09
101	6	2006-02-15 05:07:09
102	15	2006-02-15 05:07:09
103	16	2006-02-15 05:07:09
104	9	2006-02-15 05:07:09
105	1	2006-02-15 05:07:09
106	10	2006-02-15 05:07:09
107	7	2006-02-15 05:07:09
108	13	2006-02-15 05:07:09
109	13	2006-02-15 05:07:09
110	3	2006-02-15 05:07:09
111	1	2006-02-15 05:07:09
112	9	2006-02-15 05:07:09
113	15	2006-02-15 05:07:09
114	14	2006-02-15 05:07:09
115	1	2006-02-15 05:07:09
116	4	2006-02-15 05:07:09
117	10	2006-02-15 05:07:09
118	2	2006-02-15 05:07:09
119	5	2006-02-15 05:07:09
120	15	2006-02-15 05:07:09
121	2	2006-02-15 05:07:09
122	11	2006-02-15 05:07:09
123	16	2006-02-15 05:07:09
124	3	2006-02-15 05:07:09
125	16	2006-02-15 05:07:09
126	1	2006-02-15 05:07:09
127	5	2006-02-15 05:07:09
128	9	2006-02-15 05:07:09
129	6	2006-02-15 05:07:09
130	1	2006-02-15 05:07:09
131	4	2006-02-15 05:07:09
132	14	2006-02-15 05:07:09
133	12	2006-02-15 05:07:09
134	2	2006-02-15 05:07:09
135	15	2006-02-15 05:07:09
136	13	2006-02-15 05:07:09
137	14	2006-02-15 05:07:09
138	14	2006-02-15 05:07:09
139	8	2006-02-15 05:07:09
140	14	2006-02-15 05:07:09
141	10	2006-02-15 05:07:09
142	6	2006-02-15 05:07:09
143	7	2006-02-15 05:07:09
144	13	2006-02-15 05:07:09
145	8	2006-02-15 05:07:09
146	7	2006-02-15 05:07:09
147	8	2006-02-15 05:07:09
148	9	2006-02-15 05:07:09
149	3	2006-02-15 05:07:09
150	6	2006-02-15 05:07:09
151	14	2006-02-15 05:07:09
152	3	2006-02-15 05:07:09
153	14	2006-02-15 05:07:09
154	2	2006-02-15 05:07:09
155	13	2006-02-15 05:07:09
156	6	2006-02-15 05:07:09
157	3	2006-02-15 05:07:09
158	12	2006-02-15 05:07:09
159	5	2006-02-15 05:07:09
160	2	2006-02-15 05:07:09
161	12	2006-02-15 05:07:09
162	1	2006-02-15 05:07:09
163	13	2006-02-15 05:07:09
164	6	2006-02-15 05:07:09
165	14	2006-02-15 05:07:09
166	4	2006-02-15 05:07:09
167	16	2006-02-15 05:07:09
168	3	2006-02-15 05:07:09
169	16	2006-02-15 05:07:09
170	9	2006-02-15 05:07:09
171	11	2006-02-15 05:07:09
172	7	2006-02-15 05:07:09
173	7	2006-02-15 05:07:09
174	12	2006-02-15 05:07:09
175	8	2006-02-15 05:07:09
176	15	2006-02-15 05:07:09
177	14	2006-02-15 05:07:09
178	5	2006-02-15 05:07:09
179	7	2006-02-15 05:07:09
180	4	2006-02-15 05:07:09
181	16	2006-02-15 05:07:09
182	5	2006-02-15 05:07:09
183	8	2006-02-15 05:07:09
184	4	2006-02-15 05:07:09
185	9	2006-02-15 05:07:09
186	7	2006-02-15 05:07:09
187	15	2006-02-15 05:07:09
188	5	2006-02-15 05:07:09
189	10	2006-02-15 05:07:09
190	4	2006-02-15 05:07:09
191	3	2006-02-15 05:07:09
192	9	2006-02-15 05:07:09
193	2	2006-02-15 05:07:09
194	1	2006-02-15 05:07:09
195	14	2006-02-15 05:07:09
196	4	2006-02-15 05:07:09
197	15	2006-02-15 05:07:09
198	9	2006-02-15 05:07:09
199	6	2006-02-15 05:07:09
200	10	2006-02-15 05:07:09
201	9	2006-02-15 05:07:09
202	5	2006-02-15 05:07:09
203	14	2006-02-15 05:07:09
204	7	2006-02-15 05:07:09
205	1	2006-02-15 05:07:09
206	6	2006-02-15 05:07:09
207	9	2006-02-15 05:07:09
208	2	2006-02-15 05:07:09
209	7	2006-02-15 05:07:09
210	1	2006-02-15 05:07:09
211	10	2006-02-15 05:07:09
212	1	2006-02-15 05:07:09
213	8	2006-02-15 05:07:09
214	3	2006-02-15 05:07:09
215	10	2006-02-15 05:07:09
216	13	2006-02-15 05:07:09
217	10	2006-02-15 05:07:09
218	7	2006-02-15 05:07:09
219	6	2006-02-15 05:07:09
220	12	2006-02-15 05:07:09
221	6	2006-02-15 05:07:09
222	11	2006-02-15 05:07:09
223	2	2006-02-15 05:07:09
224	16	2006-02-15 05:07:09
225	7	2006-02-15 05:07:09
226	13	2006-02-15 05:07:09
227	10	2006-02-15 05:07:09
228	4	2006-02-15 05:07:09
229	1	2006-02-15 05:07:09
230	7	2006-02-15 05:07:09
231	8	2006-02-15 05:07:09
232	10	2006-02-15 05:07:09
233	16	2006-02-15 05:07:09
234	14	2006-02-15 05:07:09
235	14	2006-02-15 05:07:09
236	10	2006-02-15 05:07:09
237	15	2006-02-15 05:07:09
238	3	2006-02-15 05:07:09
239	2	2006-02-15 05:07:09
240	14	2006-02-15 05:07:09
241	2	2006-02-15 05:07:09
242	5	2006-02-15 05:07:09
243	2	2006-02-15 05:07:09
244	12	2006-02-15 05:07:09
245	2	2006-02-15 05:07:09
246	9	2006-02-15 05:07:09
247	5	2006-02-15 05:07:09
248	6	2006-02-15 05:07:09
249	4	2006-02-15 05:07:09
250	1	2006-02-15 05:07:09
251	13	2006-02-15 05:07:09
252	1	2006-02-15 05:07:09
253	1	2006-02-15 05:07:09
254	15	2006-02-15 05:07:09
255	12	2006-02-15 05:07:09
256	15	2006-02-15 05:07:09
257	16	2006-02-15 05:07:09
258	11	2006-02-15 05:07:09
259	2	2006-02-15 05:07:09
260	15	2006-02-15 05:07:09
261	6	2006-02-15 05:07:09
262	8	2006-02-15 05:07:09
263	15	2006-02-15 05:07:09
264	10	2006-02-15 05:07:09
265	5	2006-02-15 05:07:09
266	4	2006-02-15 05:07:09
267	13	2006-02-15 05:07:09
268	2	2006-02-15 05:07:09
269	8	2006-02-15 05:07:09
270	13	2006-02-15 05:07:09
271	1	2006-02-15 05:07:09
272	7	2006-02-15 05:07:09
273	8	2006-02-15 05:07:09
274	6	2006-02-15 05:07:09
275	11	2006-02-15 05:07:09
276	5	2006-02-15 05:07:09
277	11	2006-02-15 05:07:09
278	12	2006-02-15 05:07:09
279	15	2006-02-15 05:07:09
280	3	2006-02-15 05:07:09
281	10	2006-02-15 05:07:09
282	7	2006-02-15 05:07:09
283	13	2006-02-15 05:07:09
284	12	2006-02-15 05:07:09
285	14	2006-02-15 05:07:09
286	16	2006-02-15 05:07:09
287	1	2006-02-15 05:07:09
288	16	2006-02-15 05:07:09
289	13	2006-02-15 05:07:09
290	9	2006-02-15 05:07:09
291	15	2006-02-15 05:07:09
292	1	2006-02-15 05:07:09
293	15	2006-02-15 05:07:09
294	16	2006-02-15 05:07:09
295	6	2006-02-15 05:07:09
296	14	2006-02-15 05:07:09
297	4	2006-02-15 05:07:09
298	14	2006-02-15 05:07:09
299	16	2006-02-15 05:07:09
300	2	2006-02-15 05:07:09
301	11	2006-02-15 05:07:09
302	10	2006-02-15 05:07:09
303	1	2006-02-15 05:07:09
304	3	2006-02-15 05:07:09
305	13	2006-02-15 05:07:09
306	10	2006-02-15 05:07:09
307	16	2006-02-15 05:07:09
308	5	2006-02-15 05:07:09
309	8	2006-02-15 05:07:09
310	10	2006-02-15 05:07:09
311	9	2006-02-15 05:07:09
312	14	2006-02-15 05:07:09
313	11	2006-02-15 05:07:09
314	2	2006-02-15 05:07:09
315	8	2006-02-15 05:07:09
316	10	2006-02-15 05:07:09
317	5	2006-02-15 05:07:09
318	1	2006-02-15 05:07:09
319	14	2006-02-15 05:07:09
320	13	2006-02-15 05:07:09
321	13	2006-02-15 05:07:09
322	15	2006-02-15 05:07:09
323	15	2006-02-15 05:07:09
324	5	2006-02-15 05:07:09
325	2	2006-02-15 05:07:09
326	2	2006-02-15 05:07:09
327	1	2006-02-15 05:07:09
328	3	2006-02-15 05:07:09
329	1	2006-02-15 05:07:09
330	2	2006-02-15 05:07:09
331	10	2006-02-15 05:07:09
332	5	2006-02-15 05:07:09
333	12	2006-02-15 05:07:09
334	11	2006-02-15 05:07:09
335	5	2006-02-15 05:07:09
336	6	2006-02-15 05:07:09
337	9	2006-02-15 05:07:09
338	14	2006-02-15 05:07:09
339	16	2006-02-15 05:07:09
340	13	2006-02-15 05:07:09
341	4	2006-02-15 05:07:09
342	16	2006-02-15 05:07:09
343	3	2006-02-15 05:07:09
344	3	2006-02-15 05:07:09
345	8	2006-02-15 05:07:09
346	4	2006-02-15 05:07:09
347	16	2006-02-15 05:07:09
348	8	2006-02-15 05:07:09
349	2	2006-02-15 05:07:09
350	14	2006-02-15 05:07:09
351	11	2006-02-15 05:07:09
352	10	2006-02-15 05:07:09
353	9	2006-02-15 05:07:09
354	3	2006-02-15 05:07:09
355	2	2006-02-15 05:07:09
356	3	2006-02-15 05:07:09
357	4	2006-02-15 05:07:09
358	4	2006-02-15 05:07:09
359	8	2006-02-15 05:07:09
360	1	2006-02-15 05:07:09
361	15	2006-02-15 05:07:09
362	10	2006-02-15 05:07:09
363	12	2006-02-15 05:07:09
364	13	2006-02-15 05:07:09
365	5	2006-02-15 05:07:09
366	7	2006-02-15 05:07:09
367	14	2006-02-15 05:07:09
368	7	2006-02-15 05:07:09
369	14	2006-02-15 05:07:09
370	3	2006-02-15 05:07:09
371	1	2006-02-15 05:07:09
372	15	2006-02-15 05:07:09
373	3	2006-02-15 05:07:09
374	14	2006-02-15 05:07:09
375	1	2006-02-15 05:07:09
376	9	2006-02-15 05:07:09
377	8	2006-02-15 05:07:09
378	12	2006-02-15 05:07:09
379	7	2006-02-15 05:07:09
380	9	2006-02-15 05:07:09
381	10	2006-02-15 05:07:09
382	10	2006-02-15 05:07:09
383	15	2006-02-15 05:07:09
384	12	2006-02-15 05:07:09
385	5	2006-02-15 05:07:09
386	16	2006-02-15 05:07:09
387	10	2006-02-15 05:07:09
388	5	2006-02-15 05:07:09
389	15	2006-02-15 05:07:09
390	14	2006-02-15 05:07:09
391	8	2006-02-15 05:07:09
392	3	2006-02-15 05:07:09
393	6	2006-02-15 05:07:09
394	14	2006-02-15 05:07:09
395	1	2006-02-15 05:07:09
396	7	2006-02-15 05:07:09
397	14	2006-02-15 05:07:09
398	12	2006-02-15 05:07:09
399	9	2006-02-15 05:07:09
400	6	2006-02-15 05:07:09
401	7	2006-02-15 05:07:09
402	2	2006-02-15 05:07:09
403	7	2006-02-15 05:07:09
404	5	2006-02-15 05:07:09
405	16	2006-02-15 05:07:09
406	10	2006-02-15 05:07:09
407	6	2006-02-15 05:07:09
408	10	2006-02-15 05:07:09
409	3	2006-02-15 05:07:09
410	5	2006-02-15 05:07:09
411	12	2006-02-15 05:07:09
412	6	2006-02-15 05:07:09
413	5	2006-02-15 05:07:09
414	9	2006-02-15 05:07:09
415	11	2006-02-15 05:07:09
416	9	2006-02-15 05:07:09
417	1	2006-02-15 05:07:09
418	7	2006-02-15 05:07:09
419	8	2006-02-15 05:07:09
420	15	2006-02-15 05:07:09
421	9	2006-02-15 05:07:09
422	14	2006-02-15 05:07:09
423	3	2006-02-15 05:07:09
424	3	2006-02-15 05:07:09
425	4	2006-02-15 05:07:09
426	12	2006-02-15 05:07:09
427	6	2006-02-15 05:07:09
428	8	2006-02-15 05:07:09
429	15	2006-02-15 05:07:09
430	2	2006-02-15 05:07:09
431	9	2006-02-15 05:07:09
432	4	2006-02-15 05:07:09
433	2	2006-02-15 05:07:09
434	16	2006-02-15 05:07:09
435	9	2006-02-15 05:07:09
436	13	2006-02-15 05:07:09
437	8	2006-02-15 05:07:09
438	10	2006-02-15 05:07:09
439	7	2006-02-15 05:07:09
440	9	2006-02-15 05:07:09
441	6	2006-02-15 05:07:09
442	8	2006-02-15 05:07:09
443	5	2006-02-15 05:07:09
444	5	2006-02-15 05:07:09
445	4	2006-02-15 05:07:09
446	15	2006-02-15 05:07:09
447	10	2006-02-15 05:07:09
448	13	2006-02-15 05:07:09
449	14	2006-02-15 05:07:09
450	3	2006-02-15 05:07:09
451	16	2006-02-15 05:07:09
452	9	2006-02-15 05:07:09
453	15	2006-02-15 05:07:09
454	12	2006-02-15 05:07:09
455	9	2006-02-15 05:07:09
456	2	2006-02-15 05:07:09
457	6	2006-02-15 05:07:09
458	8	2006-02-15 05:07:09
459	9	2006-02-15 05:07:09
460	9	2006-02-15 05:07:09
461	2	2006-02-15 05:07:09
462	12	2006-02-15 05:07:09
463	15	2006-02-15 05:07:09
464	2	2006-02-15 05:07:09
465	13	2006-02-15 05:07:09
466	6	2006-02-15 05:07:09
467	9	2006-02-15 05:07:09
468	3	2006-02-15 05:07:09
469	4	2006-02-15 05:07:09
470	2	2006-02-15 05:07:09
471	4	2006-02-15 05:07:09
472	16	2006-02-15 05:07:09
473	7	2006-02-15 05:07:09
474	15	2006-02-15 05:07:09
475	11	2006-02-15 05:07:09
476	8	2006-02-15 05:07:09
477	12	2006-02-15 05:07:09
478	5	2006-02-15 05:07:09
479	8	2006-02-15 05:07:09
480	4	2006-02-15 05:07:09
481	13	2006-02-15 05:07:09
482	4	2006-02-15 05:07:09
483	10	2006-02-15 05:07:09
484	4	2006-02-15 05:07:09
485	3	2006-02-15 05:07:09
486	9	2006-02-15 05:07:09
487	4	2006-02-15 05:07:09
488	15	2006-02-15 05:07:09
489	2	2006-02-15 05:07:09
490	13	2006-02-15 05:07:09
491	3	2006-02-15 05:07:09
492	13	2006-02-15 05:07:09
493	9	2006-02-15 05:07:09
494	11	2006-02-15 05:07:09
495	11	2006-02-15 05:07:09
496	16	2006-02-15 05:07:09
497	6	2006-02-15 05:07:09
498	8	2006-02-15 05:07:09
499	8	2006-02-15 05:07:09
500	9	2006-02-15 05:07:09
501	1	2006-02-15 05:07:09
502	5	2006-02-15 05:07:09
503	15	2006-02-15 05:07:09
504	7	2006-02-15 05:07:09
505	3	2006-02-15 05:07:09
506	11	2006-02-15 05:07:09
507	10	2006-02-15 05:07:09
508	10	2006-02-15 05:07:09
509	3	2006-02-15 05:07:09
510	2	2006-02-15 05:07:09
511	1	2006-02-15 05:07:09
512	4	2006-02-15 05:07:09
513	16	2006-02-15 05:07:09
514	7	2006-02-15 05:07:09
515	3	2006-02-15 05:07:09
516	12	2006-02-15 05:07:09
517	15	2006-02-15 05:07:09
518	16	2006-02-15 05:07:09
519	15	2006-02-15 05:07:09
520	14	2006-02-15 05:07:09
521	7	2006-02-15 05:07:09
522	5	2006-02-15 05:07:09
523	4	2006-02-15 05:07:09
524	5	2006-02-15 05:07:09
525	4	2006-02-15 05:07:09
526	16	2006-02-15 05:07:09
527	11	2006-02-15 05:07:09
528	8	2006-02-15 05:07:09
529	5	2006-02-15 05:07:09
530	1	2006-02-15 05:07:09
531	9	2006-02-15 05:07:09
532	15	2006-02-15 05:07:09
533	9	2006-02-15 05:07:09
534	8	2006-02-15 05:07:09
535	11	2006-02-15 05:07:09
536	4	2006-02-15 05:07:09
537	4	2006-02-15 05:07:09
538	13	2006-02-15 05:07:09
539	7	2006-02-15 05:07:09
540	12	2006-02-15 05:07:09
541	2	2006-02-15 05:07:09
542	1	2006-02-15 05:07:09
543	16	2006-02-15 05:07:09
544	6	2006-02-15 05:07:09
545	9	2006-02-15 05:07:09
546	10	2006-02-15 05:07:09
547	3	2006-02-15 05:07:09
548	4	2006-02-15 05:07:09
549	1	2006-02-15 05:07:09
550	8	2006-02-15 05:07:09
551	13	2006-02-15 05:07:09
552	6	2006-02-15 05:07:09
553	3	2006-02-15 05:07:09
554	4	2006-02-15 05:07:09
555	5	2006-02-15 05:07:09
556	10	2006-02-15 05:07:09
557	8	2006-02-15 05:07:09
558	13	2006-02-15 05:07:09
559	14	2006-02-15 05:07:09
560	10	2006-02-15 05:07:09
561	13	2006-02-15 05:07:09
562	12	2006-02-15 05:07:09
563	10	2006-02-15 05:07:09
564	2	2006-02-15 05:07:09
565	9	2006-02-15 05:07:09
566	9	2006-02-15 05:07:09
567	9	2006-02-15 05:07:09
568	5	2006-02-15 05:07:09
569	2	2006-02-15 05:07:09
570	15	2006-02-15 05:07:09
571	6	2006-02-15 05:07:09
572	14	2006-02-15 05:07:09
573	3	2006-02-15 05:07:09
574	1	2006-02-15 05:07:09
575	6	2006-02-15 05:07:09
576	6	2006-02-15 05:07:09
577	15	2006-02-15 05:07:09
578	4	2006-02-15 05:07:09
579	1	2006-02-15 05:07:09
580	13	2006-02-15 05:07:09
581	12	2006-02-15 05:07:09
582	2	2006-02-15 05:07:09
583	2	2006-02-15 05:07:09
584	9	2006-02-15 05:07:09
585	7	2006-02-15 05:07:09
586	1	2006-02-15 05:07:09
587	6	2006-02-15 05:07:09
588	3	2006-02-15 05:07:09
589	6	2006-02-15 05:07:09
590	13	2006-02-15 05:07:09
591	10	2006-02-15 05:07:09
592	12	2006-02-15 05:07:09
593	11	2006-02-15 05:07:09
594	1	2006-02-15 05:07:09
595	9	2006-02-15 05:07:09
596	10	2006-02-15 05:07:09
597	10	2006-02-15 05:07:09
598	15	2006-02-15 05:07:09
599	15	2006-02-15 05:07:09
600	11	2006-02-15 05:07:09
601	16	2006-02-15 05:07:09
602	14	2006-02-15 05:07:09
603	8	2006-02-15 05:07:09
604	5	2006-02-15 05:07:09
605	9	2006-02-15 05:07:09
606	15	2006-02-15 05:07:09
607	9	2006-02-15 05:07:09
608	3	2006-02-15 05:07:09
609	16	2006-02-15 05:07:09
610	8	2006-02-15 05:07:09
611	4	2006-02-15 05:07:09
612	15	2006-02-15 05:07:09
613	5	2006-02-15 05:07:09
614	10	2006-02-15 05:07:09
615	2	2006-02-15 05:07:09
616	6	2006-02-15 05:07:09
617	8	2006-02-15 05:07:09
618	7	2006-02-15 05:07:09
619	15	2006-02-15 05:07:09
620	14	2006-02-15 05:07:09
621	8	2006-02-15 05:07:09
622	6	2006-02-15 05:07:09
623	9	2006-02-15 05:07:09
624	10	2006-02-15 05:07:09
625	14	2006-02-15 05:07:09
626	3	2006-02-15 05:07:09
627	6	2006-02-15 05:07:09
628	15	2006-02-15 05:07:09
629	6	2006-02-15 05:07:09
630	7	2006-02-15 05:07:09
631	15	2006-02-15 05:07:09
632	13	2006-02-15 05:07:09
633	4	2006-02-15 05:07:09
634	8	2006-02-15 05:07:09
635	13	2006-02-15 05:07:09
636	12	2006-02-15 05:07:09
637	14	2006-02-15 05:07:09
638	5	2006-02-15 05:07:09
639	8	2006-02-15 05:07:09
640	9	2006-02-15 05:07:09
641	9	2006-02-15 05:07:09
642	16	2006-02-15 05:07:09
643	7	2006-02-15 05:07:09
644	2	2006-02-15 05:07:09
645	16	2006-02-15 05:07:09
646	10	2006-02-15 05:07:09
647	12	2006-02-15 05:07:09
648	16	2006-02-15 05:07:09
649	2	2006-02-15 05:07:09
650	6	2006-02-15 05:07:09
651	2	2006-02-15 05:07:09
652	4	2006-02-15 05:07:09
653	11	2006-02-15 05:07:09
654	10	2006-02-15 05:07:09
655	14	2006-02-15 05:07:09
656	16	2006-02-15 05:07:09
657	5	2006-02-15 05:07:09
658	11	2006-02-15 05:07:09
659	1	2006-02-15 05:07:09
660	5	2006-02-15 05:07:09
661	9	2006-02-15 05:07:09
662	7	2006-02-15 05:07:09
663	4	2006-02-15 05:07:09
664	1	2006-02-15 05:07:09
665	11	2006-02-15 05:07:09
666	7	2006-02-15 05:07:09
667	15	2006-02-15 05:07:09
668	15	2006-02-15 05:07:09
669	9	2006-02-15 05:07:09
670	6	2006-02-15 05:07:09
671	15	2006-02-15 05:07:09
672	5	2006-02-15 05:07:09
673	12	2006-02-15 05:07:09
674	9	2006-02-15 05:07:09
675	13	2006-02-15 05:07:09
676	15	2006-02-15 05:07:09
677	13	2006-02-15 05:07:09
678	15	2006-02-15 05:07:09
679	8	2006-02-15 05:07:09
680	5	2006-02-15 05:07:09
681	15	2006-02-15 05:07:09
682	8	2006-02-15 05:07:09
683	7	2006-02-15 05:07:09
684	10	2006-02-15 05:07:09
685	13	2006-02-15 05:07:09
686	13	2006-02-15 05:07:09
687	6	2006-02-15 05:07:09
688	3	2006-02-15 05:07:09
689	9	2006-02-15 05:07:09
690	2	2006-02-15 05:07:09
691	15	2006-02-15 05:07:09
692	2	2006-02-15 05:07:09
693	2	2006-02-15 05:07:09
694	4	2006-02-15 05:07:09
695	8	2006-02-15 05:07:09
696	2	2006-02-15 05:07:09
697	1	2006-02-15 05:07:09
698	6	2006-02-15 05:07:09
699	10	2006-02-15 05:07:09
700	8	2006-02-15 05:07:09
701	10	2006-02-15 05:07:09
702	11	2006-02-15 05:07:09
703	2	2006-02-15 05:07:09
704	5	2006-02-15 05:07:09
705	9	2006-02-15 05:07:09
706	7	2006-02-15 05:07:09
707	1	2006-02-15 05:07:09
708	6	2006-02-15 05:07:09
709	7	2006-02-15 05:07:09
710	8	2006-02-15 05:07:09
711	14	2006-02-15 05:07:09
712	6	2006-02-15 05:07:09
713	6	2006-02-15 05:07:09
714	14	2006-02-15 05:07:09
715	8	2006-02-15 05:07:09
716	11	2006-02-15 05:07:09
717	1	2006-02-15 05:07:09
718	12	2006-02-15 05:07:09
719	15	2006-02-15 05:07:09
720	13	2006-02-15 05:07:09
721	12	2006-02-15 05:07:09
722	11	2006-02-15 05:07:09
723	14	2006-02-15 05:07:09
724	8	2006-02-15 05:07:09
725	4	2006-02-15 05:07:09
726	9	2006-02-15 05:07:09
727	8	2006-02-15 05:07:09
728	7	2006-02-15 05:07:09
729	15	2006-02-15 05:07:09
730	13	2006-02-15 05:07:09
731	4	2006-02-15 05:07:09
732	1	2006-02-15 05:07:09
733	15	2006-02-15 05:07:09
734	6	2006-02-15 05:07:09
735	3	2006-02-15 05:07:09
736	8	2006-02-15 05:07:09
737	11	2006-02-15 05:07:09
738	9	2006-02-15 05:07:09
739	7	2006-02-15 05:07:09
740	11	2006-02-15 05:07:09
741	12	2006-02-15 05:07:09
742	10	2006-02-15 05:07:09
743	2	2006-02-15 05:07:09
744	4	2006-02-15 05:07:09
745	15	2006-02-15 05:07:09
746	10	2006-02-15 05:07:09
747	10	2006-02-15 05:07:09
748	1	2006-02-15 05:07:09
749	11	2006-02-15 05:07:09
750	13	2006-02-15 05:07:09
751	13	2006-02-15 05:07:09
752	12	2006-02-15 05:07:09
753	8	2006-02-15 05:07:09
754	5	2006-02-15 05:07:09
755	3	2006-02-15 05:07:09
756	5	2006-02-15 05:07:09
757	6	2006-02-15 05:07:09
758	7	2006-02-15 05:07:09
759	13	2006-02-15 05:07:09
760	13	2006-02-15 05:07:09
761	3	2006-02-15 05:07:09
762	10	2006-02-15 05:07:09
763	15	2006-02-15 05:07:09
764	15	2006-02-15 05:07:09
765	5	2006-02-15 05:07:09
766	7	2006-02-15 05:07:09
767	12	2006-02-15 05:07:09
768	3	2006-02-15 05:07:09
769	9	2006-02-15 05:07:09
770	9	2006-02-15 05:07:09
771	7	2006-02-15 05:07:09
772	7	2006-02-15 05:07:09
773	15	2006-02-15 05:07:09
774	5	2006-02-15 05:07:09
775	7	2006-02-15 05:07:09
776	6	2006-02-15 05:07:09
777	15	2006-02-15 05:07:09
778	8	2006-02-15 05:07:09
779	15	2006-02-15 05:07:09
780	8	2006-02-15 05:07:09
781	10	2006-02-15 05:07:09
782	15	2006-02-15 05:07:09
783	16	2006-02-15 05:07:09
784	16	2006-02-15 05:07:09
785	16	2006-02-15 05:07:09
786	3	2006-02-15 05:07:09
787	16	2006-02-15 05:07:09
788	6	2006-02-15 05:07:09
789	9	2006-02-15 05:07:09
790	7	2006-02-15 05:07:09
791	6	2006-02-15 05:07:09
792	9	2006-02-15 05:07:09
793	1	2006-02-15 05:07:09
794	1	2006-02-15 05:07:09
795	8	2006-02-15 05:07:09
796	15	2006-02-15 05:07:09
797	12	2006-02-15 05:07:09
798	14	2006-02-15 05:07:09
799	11	2006-02-15 05:07:09
800	11	2006-02-15 05:07:09
801	3	2006-02-15 05:07:09
802	1	2006-02-15 05:07:09
803	7	2006-02-15 05:07:09
804	11	2006-02-15 05:07:09
805	2	2006-02-15 05:07:09
806	13	2006-02-15 05:07:09
807	10	2006-02-15 05:07:09
808	4	2006-02-15 05:07:09
809	15	2006-02-15 05:07:09
810	8	2006-02-15 05:07:09
811	16	2006-02-15 05:07:09
812	6	2006-02-15 05:07:09
813	15	2006-02-15 05:07:09
814	5	2006-02-15 05:07:09
815	4	2006-02-15 05:07:09
816	2	2006-02-15 05:07:09
817	14	2006-02-15 05:07:09
818	7	2006-02-15 05:07:09
819	12	2006-02-15 05:07:09
820	2	2006-02-15 05:07:09
821	9	2006-02-15 05:07:09
822	8	2006-02-15 05:07:09
823	1	2006-02-15 05:07:09
824	8	2006-02-15 05:07:09
825	1	2006-02-15 05:07:09
826	16	2006-02-15 05:07:09
827	7	2006-02-15 05:07:09
828	4	2006-02-15 05:07:09
829	8	2006-02-15 05:07:09
830	11	2006-02-15 05:07:09
831	14	2006-02-15 05:07:09
832	8	2006-02-15 05:07:09
833	3	2006-02-15 05:07:09
834	6	2006-02-15 05:07:09
835	10	2006-02-15 05:07:09
836	15	2006-02-15 05:07:09
837	5	2006-02-15 05:07:09
838	1	2006-02-15 05:07:09
839	14	2006-02-15 05:07:09
840	10	2006-02-15 05:07:09
841	15	2006-02-15 05:07:09
842	10	2006-02-15 05:07:09
843	4	2006-02-15 05:07:09
844	15	2006-02-15 05:07:09
845	9	2006-02-15 05:07:09
846	13	2006-02-15 05:07:09
847	13	2006-02-15 05:07:09
848	16	2006-02-15 05:07:09
849	2	2006-02-15 05:07:09
850	1	2006-02-15 05:07:09
851	15	2006-02-15 05:07:09
852	3	2006-02-15 05:07:09
853	3	2006-02-15 05:07:09
854	11	2006-02-15 05:07:09
855	6	2006-02-15 05:07:09
856	11	2006-02-15 05:07:09
857	5	2006-02-15 05:07:09
858	5	2006-02-15 05:07:09
859	2	2006-02-15 05:07:09
860	14	2006-02-15 05:07:09
861	10	2006-02-15 05:07:09
862	4	2006-02-15 05:07:09
863	14	2006-02-15 05:07:09
864	3	2006-02-15 05:07:09
865	2	2006-02-15 05:07:09
866	8	2006-02-15 05:07:09
867	8	2006-02-15 05:07:09
868	16	2006-02-15 05:07:09
869	1	2006-02-15 05:07:09
870	11	2006-02-15 05:07:09
871	5	2006-02-15 05:07:09
872	16	2006-02-15 05:07:09
873	3	2006-02-15 05:07:09
874	4	2006-02-15 05:07:09
875	15	2006-02-15 05:07:09
876	11	2006-02-15 05:07:09
877	12	2006-02-15 05:07:09
878	16	2006-02-15 05:07:09
879	12	2006-02-15 05:07:09
880	2	2006-02-15 05:07:09
881	11	2006-02-15 05:07:09
882	7	2006-02-15 05:07:09
883	3	2006-02-15 05:07:09
884	12	2006-02-15 05:07:09
885	11	2006-02-15 05:07:09
886	2	2006-02-15 05:07:09
887	2	2006-02-15 05:07:09
888	6	2006-02-15 05:07:09
889	3	2006-02-15 05:07:09
890	15	2006-02-15 05:07:09
891	4	2006-02-15 05:07:09
892	2	2006-02-15 05:07:09
893	14	2006-02-15 05:07:09
894	16	2006-02-15 05:07:09
895	4	2006-02-15 05:07:09
896	3	2006-02-15 05:07:09
897	7	2006-02-15 05:07:09
898	15	2006-02-15 05:07:09
899	4	2006-02-15 05:07:09
900	9	2006-02-15 05:07:09
901	2	2006-02-15 05:07:09
902	15	2006-02-15 05:07:09
903	16	2006-02-15 05:07:09
904	11	2006-02-15 05:07:09
905	5	2006-02-15 05:07:09
906	5	2006-02-15 05:07:09
907	7	2006-02-15 05:07:09
908	9	2006-02-15 05:07:09
909	11	2006-02-15 05:07:09
910	7	2006-02-15 05:07:09
911	1	2006-02-15 05:07:09
912	14	2006-02-15 05:07:09
913	13	2006-02-15 05:07:09
914	16	2006-02-15 05:07:09
915	1	2006-02-15 05:07:09
916	2	2006-02-15 05:07:09
917	15	2006-02-15 05:07:09
918	3	2006-02-15 05:07:09
919	10	2006-02-15 05:07:09
920	13	2006-02-15 05:07:09
921	12	2006-02-15 05:07:09
922	11	2006-02-15 05:07:09
923	7	2006-02-15 05:07:09
924	14	2006-02-15 05:07:09
925	6	2006-02-15 05:07:09
926	6	2006-02-15 05:07:09
927	1	2006-02-15 05:07:09
928	3	2006-02-15 05:07:09
929	9	2006-02-15 05:07:09
930	14	2006-02-15 05:07:09
931	16	2006-02-15 05:07:09
932	5	2006-02-15 05:07:09
933	13	2006-02-15 05:07:09
934	10	2006-02-15 05:07:09
935	13	2006-02-15 05:07:09
936	12	2006-02-15 05:07:09
937	13	2006-02-15 05:07:09
938	5	2006-02-15 05:07:09
939	5	2006-02-15 05:07:09
940	15	2006-02-15 05:07:09
941	10	2006-02-15 05:07:09
942	7	2006-02-15 05:07:09
943	6	2006-02-15 05:07:09
944	7	2006-02-15 05:07:09
945	6	2006-02-15 05:07:09
946	8	2006-02-15 05:07:09
947	9	2006-02-15 05:07:09
948	13	2006-02-15 05:07:09
949	10	2006-02-15 05:07:09
950	4	2006-02-15 05:07:09
951	4	2006-02-15 05:07:09
952	6	2006-02-15 05:07:09
953	2	2006-02-15 05:07:09
954	13	2006-02-15 05:07:09
955	3	2006-02-15 05:07:09
956	10	2006-02-15 05:07:09
957	9	2006-02-15 05:07:09
958	7	2006-02-15 05:07:09
959	3	2006-02-15 05:07:09
960	6	2006-02-15 05:07:09
961	9	2006-02-15 05:07:09
962	4	2006-02-15 05:07:09
963	2	2006-02-15 05:07:09
964	1	2006-02-15 05:07:09
965	11	2006-02-15 05:07:09
966	6	2006-02-15 05:07:09
967	14	2006-02-15 05:07:09
968	1	2006-02-15 05:07:09
969	7	2006-02-15 05:07:09
970	4	2006-02-15 05:07:09
971	9	2006-02-15 05:07:09
972	14	2006-02-15 05:07:09
973	6	2006-02-15 05:07:09
974	13	2006-02-15 05:07:09
975	8	2006-02-15 05:07:09
976	10	2006-02-15 05:07:09
977	16	2006-02-15 05:07:09
978	5	2006-02-15 05:07:09
979	7	2006-02-15 05:07:09
980	12	2006-02-15 05:07:09
981	16	2006-02-15 05:07:09
982	1	2006-02-15 05:07:09
983	12	2006-02-15 05:07:09
984	9	2006-02-15 05:07:09
985	14	2006-02-15 05:07:09
986	2	2006-02-15 05:07:09
987	12	2006-02-15 05:07:09
988	16	2006-02-15 05:07:09
989	16	2006-02-15 05:07:09
990	11	2006-02-15 05:07:09
991	1	2006-02-15 05:07:09
992	6	2006-02-15 05:07:09
993	3	2006-02-15 05:07:09
994	13	2006-02-15 05:07:09
995	11	2006-02-15 05:07:09
996	6	2006-02-15 05:07:09
997	12	2006-02-15 05:07:09
998	11	2006-02-15 05:07:09
999	3	2006-02-15 05:07:09
1000	5	2006-02-15 05:07:09
\.


--
-- Data for Name: inventory; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.inventory (inventory_id, film_id, store_id, last_update) FROM stdin;
1	1	1	2006-02-15 05:09:17
2	1	1	2006-02-15 05:09:17
3	1	1	2006-02-15 05:09:17
4	1	1	2006-02-15 05:09:17
5	1	2	2006-02-15 05:09:17
6	1	2	2006-02-15 05:09:17
7	1	2	2006-02-15 05:09:17
8	1	2	2006-02-15 05:09:17
9	2	2	2006-02-15 05:09:17
10	2	2	2006-02-15 05:09:17
11	2	2	2006-02-15 05:09:17
12	3	2	2006-02-15 05:09:17
13	3	2	2006-02-15 05:09:17
14	3	2	2006-02-15 05:09:17
15	3	2	2006-02-15 05:09:17
16	4	1	2006-02-15 05:09:17
17	4	1	2006-02-15 05:09:17
18	4	1	2006-02-15 05:09:17
19	4	1	2006-02-15 05:09:17
20	4	2	2006-02-15 05:09:17
21	4	2	2006-02-15 05:09:17
22	4	2	2006-02-15 05:09:17
23	5	2	2006-02-15 05:09:17
24	5	2	2006-02-15 05:09:17
25	5	2	2006-02-15 05:09:17
26	6	1	2006-02-15 05:09:17
27	6	1	2006-02-15 05:09:17
28	6	1	2006-02-15 05:09:17
29	6	2	2006-02-15 05:09:17
30	6	2	2006-02-15 05:09:17
31	6	2	2006-02-15 05:09:17
32	7	1	2006-02-15 05:09:17
33	7	1	2006-02-15 05:09:17
34	7	2	2006-02-15 05:09:17
35	7	2	2006-02-15 05:09:17
36	7	2	2006-02-15 05:09:17
37	8	2	2006-02-15 05:09:17
38	8	2	2006-02-15 05:09:17
39	8	2	2006-02-15 05:09:17
40	8	2	2006-02-15 05:09:17
41	9	1	2006-02-15 05:09:17
42	9	1	2006-02-15 05:09:17
43	9	1	2006-02-15 05:09:17
44	9	2	2006-02-15 05:09:17
45	9	2	2006-02-15 05:09:17
46	10	1	2006-02-15 05:09:17
47	10	1	2006-02-15 05:09:17
48	10	1	2006-02-15 05:09:17
49	10	1	2006-02-15 05:09:17
50	10	2	2006-02-15 05:09:17
51	10	2	2006-02-15 05:09:17
52	10	2	2006-02-15 05:09:17
53	11	1	2006-02-15 05:09:17
54	11	1	2006-02-15 05:09:17
55	11	1	2006-02-15 05:09:17
56	11	1	2006-02-15 05:09:17
57	11	2	2006-02-15 05:09:17
58	11	2	2006-02-15 05:09:17
59	11	2	2006-02-15 05:09:17
60	12	1	2006-02-15 05:09:17
61	12	1	2006-02-15 05:09:17
62	12	1	2006-02-15 05:09:17
63	12	2	2006-02-15 05:09:17
64	12	2	2006-02-15 05:09:17
65	12	2	2006-02-15 05:09:17
66	12	2	2006-02-15 05:09:17
67	13	2	2006-02-15 05:09:17
68	13	2	2006-02-15 05:09:17
69	13	2	2006-02-15 05:09:17
70	13	2	2006-02-15 05:09:17
71	15	1	2006-02-15 05:09:17
72	15	1	2006-02-15 05:09:17
73	15	2	2006-02-15 05:09:17
74	15	2	2006-02-15 05:09:17
75	15	2	2006-02-15 05:09:17
76	15	2	2006-02-15 05:09:17
77	16	1	2006-02-15 05:09:17
78	16	1	2006-02-15 05:09:17
79	16	2	2006-02-15 05:09:17
80	16	2	2006-02-15 05:09:17
81	17	1	2006-02-15 05:09:17
82	17	1	2006-02-15 05:09:17
83	17	1	2006-02-15 05:09:17
84	17	2	2006-02-15 05:09:17
85	17	2	2006-02-15 05:09:17
86	17	2	2006-02-15 05:09:17
87	18	1	2006-02-15 05:09:17
88	18	1	2006-02-15 05:09:17
89	18	1	2006-02-15 05:09:17
90	18	2	2006-02-15 05:09:17
91	18	2	2006-02-15 05:09:17
92	18	2	2006-02-15 05:09:17
93	19	1	2006-02-15 05:09:17
94	19	1	2006-02-15 05:09:17
95	19	1	2006-02-15 05:09:17
96	19	1	2006-02-15 05:09:17
97	19	2	2006-02-15 05:09:17
98	19	2	2006-02-15 05:09:17
99	20	1	2006-02-15 05:09:17
100	20	1	2006-02-15 05:09:17
101	20	1	2006-02-15 05:09:17
102	21	1	2006-02-15 05:09:17
103	21	1	2006-02-15 05:09:17
104	21	2	2006-02-15 05:09:17
105	21	2	2006-02-15 05:09:17
106	21	2	2006-02-15 05:09:17
107	21	2	2006-02-15 05:09:17
108	22	1	2006-02-15 05:09:17
109	22	1	2006-02-15 05:09:17
110	22	1	2006-02-15 05:09:17
111	22	1	2006-02-15 05:09:17
112	22	2	2006-02-15 05:09:17
113	22	2	2006-02-15 05:09:17
114	22	2	2006-02-15 05:09:17
115	23	1	2006-02-15 05:09:17
116	23	1	2006-02-15 05:09:17
117	23	1	2006-02-15 05:09:17
118	23	2	2006-02-15 05:09:17
119	23	2	2006-02-15 05:09:17
120	24	1	2006-02-15 05:09:17
121	24	1	2006-02-15 05:09:17
122	24	1	2006-02-15 05:09:17
123	24	1	2006-02-15 05:09:17
124	25	1	2006-02-15 05:09:17
125	25	1	2006-02-15 05:09:17
126	25	1	2006-02-15 05:09:17
127	25	1	2006-02-15 05:09:17
128	25	2	2006-02-15 05:09:17
129	25	2	2006-02-15 05:09:17
130	26	1	2006-02-15 05:09:17
131	26	1	2006-02-15 05:09:17
132	26	2	2006-02-15 05:09:17
133	26	2	2006-02-15 05:09:17
134	26	2	2006-02-15 05:09:17
135	27	1	2006-02-15 05:09:17
136	27	1	2006-02-15 05:09:17
137	27	1	2006-02-15 05:09:17
138	27	1	2006-02-15 05:09:17
139	28	1	2006-02-15 05:09:17
140	28	1	2006-02-15 05:09:17
141	28	1	2006-02-15 05:09:17
142	29	1	2006-02-15 05:09:17
143	29	1	2006-02-15 05:09:17
144	30	1	2006-02-15 05:09:17
145	30	1	2006-02-15 05:09:17
146	31	1	2006-02-15 05:09:17
147	31	1	2006-02-15 05:09:17
148	31	1	2006-02-15 05:09:17
149	31	1	2006-02-15 05:09:17
150	31	2	2006-02-15 05:09:17
151	31	2	2006-02-15 05:09:17
152	31	2	2006-02-15 05:09:17
153	31	2	2006-02-15 05:09:17
154	32	2	2006-02-15 05:09:17
155	32	2	2006-02-15 05:09:17
156	34	2	2006-02-15 05:09:17
157	34	2	2006-02-15 05:09:17
158	34	2	2006-02-15 05:09:17
159	34	2	2006-02-15 05:09:17
160	35	1	2006-02-15 05:09:17
161	35	1	2006-02-15 05:09:17
162	35	1	2006-02-15 05:09:17
163	35	1	2006-02-15 05:09:17
164	35	2	2006-02-15 05:09:17
165	35	2	2006-02-15 05:09:17
166	35	2	2006-02-15 05:09:17
167	37	1	2006-02-15 05:09:17
168	37	1	2006-02-15 05:09:17
169	37	1	2006-02-15 05:09:17
170	37	1	2006-02-15 05:09:17
171	37	2	2006-02-15 05:09:17
172	37	2	2006-02-15 05:09:17
173	37	2	2006-02-15 05:09:17
174	39	1	2006-02-15 05:09:17
175	39	1	2006-02-15 05:09:17
176	39	1	2006-02-15 05:09:17
177	39	2	2006-02-15 05:09:17
178	39	2	2006-02-15 05:09:17
179	39	2	2006-02-15 05:09:17
180	39	2	2006-02-15 05:09:17
181	40	2	2006-02-15 05:09:17
182	40	2	2006-02-15 05:09:17
183	40	2	2006-02-15 05:09:17
184	40	2	2006-02-15 05:09:17
185	42	2	2006-02-15 05:09:17
186	42	2	2006-02-15 05:09:17
187	42	2	2006-02-15 05:09:17
188	42	2	2006-02-15 05:09:17
189	43	1	2006-02-15 05:09:17
190	43	1	2006-02-15 05:09:17
191	43	1	2006-02-15 05:09:17
192	43	2	2006-02-15 05:09:17
193	43	2	2006-02-15 05:09:17
194	43	2	2006-02-15 05:09:17
195	43	2	2006-02-15 05:09:17
196	44	1	2006-02-15 05:09:17
197	44	1	2006-02-15 05:09:17
198	44	2	2006-02-15 05:09:17
199	44	2	2006-02-15 05:09:17
200	44	2	2006-02-15 05:09:17
201	45	1	2006-02-15 05:09:17
202	45	1	2006-02-15 05:09:17
203	45	1	2006-02-15 05:09:17
204	45	1	2006-02-15 05:09:17
205	45	2	2006-02-15 05:09:17
206	45	2	2006-02-15 05:09:17
207	46	2	2006-02-15 05:09:17
208	46	2	2006-02-15 05:09:17
209	46	2	2006-02-15 05:09:17
210	47	2	2006-02-15 05:09:17
211	47	2	2006-02-15 05:09:17
212	48	1	2006-02-15 05:09:17
213	48	1	2006-02-15 05:09:17
214	48	2	2006-02-15 05:09:17
215	48	2	2006-02-15 05:09:17
216	49	1	2006-02-15 05:09:17
217	49	1	2006-02-15 05:09:17
218	49	1	2006-02-15 05:09:17
219	49	2	2006-02-15 05:09:17
220	49	2	2006-02-15 05:09:17
221	49	2	2006-02-15 05:09:17
222	50	1	2006-02-15 05:09:17
223	50	1	2006-02-15 05:09:17
224	50	1	2006-02-15 05:09:17
225	50	2	2006-02-15 05:09:17
226	50	2	2006-02-15 05:09:17
227	51	1	2006-02-15 05:09:17
228	51	1	2006-02-15 05:09:17
229	51	2	2006-02-15 05:09:17
230	51	2	2006-02-15 05:09:17
231	51	2	2006-02-15 05:09:17
232	51	2	2006-02-15 05:09:17
233	52	2	2006-02-15 05:09:17
234	52	2	2006-02-15 05:09:17
235	53	1	2006-02-15 05:09:17
236	53	1	2006-02-15 05:09:17
237	54	1	2006-02-15 05:09:17
238	54	1	2006-02-15 05:09:17
239	54	1	2006-02-15 05:09:17
240	54	2	2006-02-15 05:09:17
241	54	2	2006-02-15 05:09:17
242	55	1	2006-02-15 05:09:17
243	55	1	2006-02-15 05:09:17
244	55	1	2006-02-15 05:09:17
245	55	1	2006-02-15 05:09:17
246	55	2	2006-02-15 05:09:17
247	55	2	2006-02-15 05:09:17
248	56	1	2006-02-15 05:09:17
249	56	1	2006-02-15 05:09:17
250	56	1	2006-02-15 05:09:17
251	56	2	2006-02-15 05:09:17
252	56	2	2006-02-15 05:09:17
253	57	1	2006-02-15 05:09:17
254	57	1	2006-02-15 05:09:17
255	57	1	2006-02-15 05:09:17
256	57	1	2006-02-15 05:09:17
257	57	2	2006-02-15 05:09:17
258	57	2	2006-02-15 05:09:17
259	57	2	2006-02-15 05:09:17
260	58	2	2006-02-15 05:09:17
261	58	2	2006-02-15 05:09:17
262	58	2	2006-02-15 05:09:17
263	58	2	2006-02-15 05:09:17
264	59	1	2006-02-15 05:09:17
265	59	1	2006-02-15 05:09:17
266	59	1	2006-02-15 05:09:17
267	59	2	2006-02-15 05:09:17
268	59	2	2006-02-15 05:09:17
269	60	1	2006-02-15 05:09:17
270	60	1	2006-02-15 05:09:17
271	60	1	2006-02-15 05:09:17
272	61	1	2006-02-15 05:09:17
273	61	1	2006-02-15 05:09:17
274	61	1	2006-02-15 05:09:17
275	61	1	2006-02-15 05:09:17
276	61	2	2006-02-15 05:09:17
277	61	2	2006-02-15 05:09:17
278	62	2	2006-02-15 05:09:17
279	62	2	2006-02-15 05:09:17
280	63	1	2006-02-15 05:09:17
281	63	1	2006-02-15 05:09:17
282	63	2	2006-02-15 05:09:17
283	63	2	2006-02-15 05:09:17
284	64	2	2006-02-15 05:09:17
285	64	2	2006-02-15 05:09:17
286	64	2	2006-02-15 05:09:17
287	65	2	2006-02-15 05:09:17
288	65	2	2006-02-15 05:09:17
289	65	2	2006-02-15 05:09:17
290	65	2	2006-02-15 05:09:17
291	66	1	2006-02-15 05:09:17
292	66	1	2006-02-15 05:09:17
293	66	1	2006-02-15 05:09:17
294	67	1	2006-02-15 05:09:17
295	67	1	2006-02-15 05:09:17
296	67	2	2006-02-15 05:09:17
297	67	2	2006-02-15 05:09:17
298	67	2	2006-02-15 05:09:17
299	67	2	2006-02-15 05:09:17
300	68	1	2006-02-15 05:09:17
301	68	1	2006-02-15 05:09:17
302	68	2	2006-02-15 05:09:17
303	68	2	2006-02-15 05:09:17
304	69	1	2006-02-15 05:09:17
305	69	1	2006-02-15 05:09:17
306	69	1	2006-02-15 05:09:17
307	69	1	2006-02-15 05:09:17
308	69	2	2006-02-15 05:09:17
309	69	2	2006-02-15 05:09:17
310	69	2	2006-02-15 05:09:17
311	69	2	2006-02-15 05:09:17
312	70	1	2006-02-15 05:09:17
313	70	1	2006-02-15 05:09:17
314	70	2	2006-02-15 05:09:17
315	70	2	2006-02-15 05:09:17
316	71	2	2006-02-15 05:09:17
317	71	2	2006-02-15 05:09:17
318	71	2	2006-02-15 05:09:17
319	71	2	2006-02-15 05:09:17
320	72	1	2006-02-15 05:09:17
321	72	1	2006-02-15 05:09:17
322	72	1	2006-02-15 05:09:17
323	72	1	2006-02-15 05:09:17
324	72	2	2006-02-15 05:09:17
325	72	2	2006-02-15 05:09:17
326	73	1	2006-02-15 05:09:17
327	73	1	2006-02-15 05:09:17
328	73	1	2006-02-15 05:09:17
329	73	1	2006-02-15 05:09:17
330	73	2	2006-02-15 05:09:17
331	73	2	2006-02-15 05:09:17
332	73	2	2006-02-15 05:09:17
333	73	2	2006-02-15 05:09:17
334	74	1	2006-02-15 05:09:17
335	74	1	2006-02-15 05:09:17
336	74	1	2006-02-15 05:09:17
337	74	2	2006-02-15 05:09:17
338	74	2	2006-02-15 05:09:17
339	75	2	2006-02-15 05:09:17
340	75	2	2006-02-15 05:09:17
341	75	2	2006-02-15 05:09:17
342	76	1	2006-02-15 05:09:17
343	76	1	2006-02-15 05:09:17
344	76	1	2006-02-15 05:09:17
345	77	1	2006-02-15 05:09:17
346	77	1	2006-02-15 05:09:17
347	77	1	2006-02-15 05:09:17
348	77	1	2006-02-15 05:09:17
349	77	2	2006-02-15 05:09:17
350	77	2	2006-02-15 05:09:17
351	78	1	2006-02-15 05:09:17
352	78	1	2006-02-15 05:09:17
353	78	1	2006-02-15 05:09:17
354	78	2	2006-02-15 05:09:17
355	78	2	2006-02-15 05:09:17
356	78	2	2006-02-15 05:09:17
357	78	2	2006-02-15 05:09:17
358	79	1	2006-02-15 05:09:17
359	79	1	2006-02-15 05:09:17
360	79	1	2006-02-15 05:09:17
361	79	2	2006-02-15 05:09:17
362	79	2	2006-02-15 05:09:17
363	79	2	2006-02-15 05:09:17
364	80	1	2006-02-15 05:09:17
365	80	1	2006-02-15 05:09:17
366	80	1	2006-02-15 05:09:17
367	80	1	2006-02-15 05:09:17
368	81	1	2006-02-15 05:09:17
369	81	1	2006-02-15 05:09:17
370	81	1	2006-02-15 05:09:17
371	81	1	2006-02-15 05:09:17
372	82	1	2006-02-15 05:09:17
373	82	1	2006-02-15 05:09:17
374	83	1	2006-02-15 05:09:17
375	83	1	2006-02-15 05:09:17
376	83	1	2006-02-15 05:09:17
377	83	2	2006-02-15 05:09:17
378	83	2	2006-02-15 05:09:17
379	84	1	2006-02-15 05:09:17
380	84	1	2006-02-15 05:09:17
381	84	1	2006-02-15 05:09:17
382	84	1	2006-02-15 05:09:17
383	85	2	2006-02-15 05:09:17
384	85	2	2006-02-15 05:09:17
385	85	2	2006-02-15 05:09:17
386	85	2	2006-02-15 05:09:17
387	86	1	2006-02-15 05:09:17
388	86	1	2006-02-15 05:09:17
389	86	1	2006-02-15 05:09:17
390	86	1	2006-02-15 05:09:17
391	86	2	2006-02-15 05:09:17
392	86	2	2006-02-15 05:09:17
393	86	2	2006-02-15 05:09:17
394	86	2	2006-02-15 05:09:17
395	88	2	2006-02-15 05:09:17
396	88	2	2006-02-15 05:09:17
397	88	2	2006-02-15 05:09:17
398	88	2	2006-02-15 05:09:17
399	89	1	2006-02-15 05:09:17
400	89	1	2006-02-15 05:09:17
401	89	1	2006-02-15 05:09:17
402	89	2	2006-02-15 05:09:17
403	89	2	2006-02-15 05:09:17
404	89	2	2006-02-15 05:09:17
405	90	1	2006-02-15 05:09:17
406	90	1	2006-02-15 05:09:17
407	90	1	2006-02-15 05:09:17
408	90	2	2006-02-15 05:09:17
409	90	2	2006-02-15 05:09:17
410	90	2	2006-02-15 05:09:17
411	91	1	2006-02-15 05:09:17
412	91	1	2006-02-15 05:09:17
413	91	1	2006-02-15 05:09:17
414	91	1	2006-02-15 05:09:17
415	91	2	2006-02-15 05:09:17
416	91	2	2006-02-15 05:09:17
417	91	2	2006-02-15 05:09:17
418	91	2	2006-02-15 05:09:17
419	92	1	2006-02-15 05:09:17
420	92	1	2006-02-15 05:09:17
421	92	2	2006-02-15 05:09:17
422	92	2	2006-02-15 05:09:17
423	93	2	2006-02-15 05:09:17
424	93	2	2006-02-15 05:09:17
425	93	2	2006-02-15 05:09:17
426	94	1	2006-02-15 05:09:17
427	94	1	2006-02-15 05:09:17
428	95	1	2006-02-15 05:09:17
429	95	1	2006-02-15 05:09:17
430	95	2	2006-02-15 05:09:17
431	95	2	2006-02-15 05:09:17
432	95	2	2006-02-15 05:09:17
433	96	1	2006-02-15 05:09:17
434	96	1	2006-02-15 05:09:17
435	96	1	2006-02-15 05:09:17
436	97	1	2006-02-15 05:09:17
437	97	1	2006-02-15 05:09:17
438	97	1	2006-02-15 05:09:17
439	97	1	2006-02-15 05:09:17
440	97	2	2006-02-15 05:09:17
441	97	2	2006-02-15 05:09:17
442	98	1	2006-02-15 05:09:17
443	98	1	2006-02-15 05:09:17
444	98	1	2006-02-15 05:09:17
445	99	1	2006-02-15 05:09:17
446	99	1	2006-02-15 05:09:17
447	99	1	2006-02-15 05:09:17
448	99	2	2006-02-15 05:09:17
449	99	2	2006-02-15 05:09:17
450	99	2	2006-02-15 05:09:17
451	100	1	2006-02-15 05:09:17
452	100	1	2006-02-15 05:09:17
453	100	1	2006-02-15 05:09:17
454	100	1	2006-02-15 05:09:17
455	100	2	2006-02-15 05:09:17
456	100	2	2006-02-15 05:09:17
457	101	1	2006-02-15 05:09:17
458	101	1	2006-02-15 05:09:17
459	101	1	2006-02-15 05:09:17
460	101	1	2006-02-15 05:09:17
461	101	2	2006-02-15 05:09:17
462	101	2	2006-02-15 05:09:17
463	102	2	2006-02-15 05:09:17
464	102	2	2006-02-15 05:09:17
465	103	1	2006-02-15 05:09:17
466	103	1	2006-02-15 05:09:17
467	103	1	2006-02-15 05:09:17
468	103	1	2006-02-15 05:09:17
469	103	2	2006-02-15 05:09:17
470	103	2	2006-02-15 05:09:17
471	103	2	2006-02-15 05:09:17
472	103	2	2006-02-15 05:09:17
473	104	2	2006-02-15 05:09:17
474	104	2	2006-02-15 05:09:17
475	104	2	2006-02-15 05:09:17
476	105	1	2006-02-15 05:09:17
477	105	1	2006-02-15 05:09:17
478	105	2	2006-02-15 05:09:17
479	105	2	2006-02-15 05:09:17
480	105	2	2006-02-15 05:09:17
481	106	1	2006-02-15 05:09:17
482	106	1	2006-02-15 05:09:17
483	107	2	2006-02-15 05:09:17
484	107	2	2006-02-15 05:09:17
485	109	1	2006-02-15 05:09:17
486	109	1	2006-02-15 05:09:17
487	109	1	2006-02-15 05:09:17
488	109	1	2006-02-15 05:09:17
489	109	2	2006-02-15 05:09:17
490	109	2	2006-02-15 05:09:17
491	109	2	2006-02-15 05:09:17
492	109	2	2006-02-15 05:09:17
493	110	1	2006-02-15 05:09:17
494	110	1	2006-02-15 05:09:17
495	110	1	2006-02-15 05:09:17
496	110	1	2006-02-15 05:09:17
497	111	2	2006-02-15 05:09:17
498	111	2	2006-02-15 05:09:17
499	111	2	2006-02-15 05:09:17
500	111	2	2006-02-15 05:09:17
501	112	1	2006-02-15 05:09:17
502	112	1	2006-02-15 05:09:17
503	112	1	2006-02-15 05:09:17
504	112	1	2006-02-15 05:09:17
505	112	2	2006-02-15 05:09:17
506	112	2	2006-02-15 05:09:17
507	112	2	2006-02-15 05:09:17
508	113	2	2006-02-15 05:09:17
509	113	2	2006-02-15 05:09:17
510	113	2	2006-02-15 05:09:17
511	113	2	2006-02-15 05:09:17
512	114	1	2006-02-15 05:09:17
513	114	1	2006-02-15 05:09:17
514	114	1	2006-02-15 05:09:17
515	114	1	2006-02-15 05:09:17
516	114	2	2006-02-15 05:09:17
517	114	2	2006-02-15 05:09:17
518	114	2	2006-02-15 05:09:17
519	115	1	2006-02-15 05:09:17
520	115	1	2006-02-15 05:09:17
521	115	1	2006-02-15 05:09:17
522	115	2	2006-02-15 05:09:17
523	115	2	2006-02-15 05:09:17
524	115	2	2006-02-15 05:09:17
525	115	2	2006-02-15 05:09:17
526	116	1	2006-02-15 05:09:17
527	116	1	2006-02-15 05:09:17
528	116	2	2006-02-15 05:09:17
529	116	2	2006-02-15 05:09:17
530	116	2	2006-02-15 05:09:17
531	116	2	2006-02-15 05:09:17
532	117	1	2006-02-15 05:09:17
533	117	1	2006-02-15 05:09:17
534	117	1	2006-02-15 05:09:17
535	117	1	2006-02-15 05:09:17
536	117	2	2006-02-15 05:09:17
537	117	2	2006-02-15 05:09:17
538	118	1	2006-02-15 05:09:17
539	118	1	2006-02-15 05:09:17
540	118	1	2006-02-15 05:09:17
541	118	1	2006-02-15 05:09:17
542	118	2	2006-02-15 05:09:17
543	118	2	2006-02-15 05:09:17
544	119	1	2006-02-15 05:09:17
545	119	1	2006-02-15 05:09:17
546	119	1	2006-02-15 05:09:17
547	119	2	2006-02-15 05:09:17
548	119	2	2006-02-15 05:09:17
549	119	2	2006-02-15 05:09:17
550	119	2	2006-02-15 05:09:17
551	120	1	2006-02-15 05:09:17
552	120	1	2006-02-15 05:09:17
553	120	1	2006-02-15 05:09:17
554	121	1	2006-02-15 05:09:17
555	121	1	2006-02-15 05:09:17
556	121	1	2006-02-15 05:09:17
557	121	2	2006-02-15 05:09:17
558	121	2	2006-02-15 05:09:17
559	121	2	2006-02-15 05:09:17
560	122	1	2006-02-15 05:09:17
561	122	1	2006-02-15 05:09:17
562	122	1	2006-02-15 05:09:17
563	122	1	2006-02-15 05:09:17
564	122	2	2006-02-15 05:09:17
565	122	2	2006-02-15 05:09:17
566	122	2	2006-02-15 05:09:17
567	123	1	2006-02-15 05:09:17
568	123	1	2006-02-15 05:09:17
569	123	2	2006-02-15 05:09:17
570	123	2	2006-02-15 05:09:17
571	123	2	2006-02-15 05:09:17
572	124	2	2006-02-15 05:09:17
573	124	2	2006-02-15 05:09:17
574	124	2	2006-02-15 05:09:17
575	125	2	2006-02-15 05:09:17
576	125	2	2006-02-15 05:09:17
577	126	2	2006-02-15 05:09:17
578	126	2	2006-02-15 05:09:17
579	126	2	2006-02-15 05:09:17
580	127	1	2006-02-15 05:09:17
581	127	1	2006-02-15 05:09:17
582	127	1	2006-02-15 05:09:17
583	127	1	2006-02-15 05:09:17
584	127	2	2006-02-15 05:09:17
585	127	2	2006-02-15 05:09:17
586	127	2	2006-02-15 05:09:17
587	127	2	2006-02-15 05:09:17
588	129	1	2006-02-15 05:09:17
589	129	1	2006-02-15 05:09:17
590	129	1	2006-02-15 05:09:17
591	129	2	2006-02-15 05:09:17
592	129	2	2006-02-15 05:09:17
593	129	2	2006-02-15 05:09:17
594	130	1	2006-02-15 05:09:17
595	130	1	2006-02-15 05:09:17
596	130	2	2006-02-15 05:09:17
597	130	2	2006-02-15 05:09:17
598	130	2	2006-02-15 05:09:17
599	130	2	2006-02-15 05:09:17
600	131	1	2006-02-15 05:09:17
601	131	1	2006-02-15 05:09:17
602	131	1	2006-02-15 05:09:17
603	131	1	2006-02-15 05:09:17
604	131	2	2006-02-15 05:09:17
605	131	2	2006-02-15 05:09:17
606	132	1	2006-02-15 05:09:17
607	132	1	2006-02-15 05:09:17
608	132	1	2006-02-15 05:09:17
609	132	1	2006-02-15 05:09:17
610	132	2	2006-02-15 05:09:17
611	132	2	2006-02-15 05:09:17
612	133	1	2006-02-15 05:09:17
613	133	1	2006-02-15 05:09:17
614	133	2	2006-02-15 05:09:17
615	133	2	2006-02-15 05:09:17
616	134	2	2006-02-15 05:09:17
617	134	2	2006-02-15 05:09:17
618	134	2	2006-02-15 05:09:17
619	135	1	2006-02-15 05:09:17
620	135	1	2006-02-15 05:09:17
621	135	1	2006-02-15 05:09:17
622	135	2	2006-02-15 05:09:17
623	135	2	2006-02-15 05:09:17
624	135	2	2006-02-15 05:09:17
625	135	2	2006-02-15 05:09:17
626	136	1	2006-02-15 05:09:17
627	136	1	2006-02-15 05:09:17
628	136	1	2006-02-15 05:09:17
629	137	2	2006-02-15 05:09:17
630	137	2	2006-02-15 05:09:17
631	137	2	2006-02-15 05:09:17
632	137	2	2006-02-15 05:09:17
633	138	1	2006-02-15 05:09:17
634	138	1	2006-02-15 05:09:17
635	138	2	2006-02-15 05:09:17
636	138	2	2006-02-15 05:09:17
637	138	2	2006-02-15 05:09:17
638	139	1	2006-02-15 05:09:17
639	139	1	2006-02-15 05:09:17
640	139	1	2006-02-15 05:09:17
641	139	1	2006-02-15 05:09:17
642	139	2	2006-02-15 05:09:17
643	139	2	2006-02-15 05:09:17
644	140	1	2006-02-15 05:09:17
645	140	1	2006-02-15 05:09:17
646	140	2	2006-02-15 05:09:17
647	140	2	2006-02-15 05:09:17
648	140	2	2006-02-15 05:09:17
649	141	1	2006-02-15 05:09:17
650	141	1	2006-02-15 05:09:17
651	141	1	2006-02-15 05:09:17
652	141	2	2006-02-15 05:09:17
653	141	2	2006-02-15 05:09:17
654	142	1	2006-02-15 05:09:17
655	142	1	2006-02-15 05:09:17
656	142	1	2006-02-15 05:09:17
657	142	2	2006-02-15 05:09:17
658	142	2	2006-02-15 05:09:17
659	143	1	2006-02-15 05:09:17
660	143	1	2006-02-15 05:09:17
661	143	1	2006-02-15 05:09:17
662	143	1	2006-02-15 05:09:17
663	143	2	2006-02-15 05:09:17
664	143	2	2006-02-15 05:09:17
665	143	2	2006-02-15 05:09:17
666	145	2	2006-02-15 05:09:17
667	145	2	2006-02-15 05:09:17
668	145	2	2006-02-15 05:09:17
669	146	1	2006-02-15 05:09:17
670	146	1	2006-02-15 05:09:17
671	146	1	2006-02-15 05:09:17
672	147	1	2006-02-15 05:09:17
673	147	1	2006-02-15 05:09:17
674	147	1	2006-02-15 05:09:17
675	147	2	2006-02-15 05:09:17
676	147	2	2006-02-15 05:09:17
677	147	2	2006-02-15 05:09:17
678	149	1	2006-02-15 05:09:17
679	149	1	2006-02-15 05:09:17
680	149	1	2006-02-15 05:09:17
681	149	2	2006-02-15 05:09:17
682	149	2	2006-02-15 05:09:17
683	149	2	2006-02-15 05:09:17
684	150	1	2006-02-15 05:09:17
685	150	1	2006-02-15 05:09:17
686	150	2	2006-02-15 05:09:17
687	150	2	2006-02-15 05:09:17
688	150	2	2006-02-15 05:09:17
689	150	2	2006-02-15 05:09:17
690	151	1	2006-02-15 05:09:17
691	151	1	2006-02-15 05:09:17
692	151	2	2006-02-15 05:09:17
693	151	2	2006-02-15 05:09:17
694	152	1	2006-02-15 05:09:17
695	152	1	2006-02-15 05:09:17
696	152	1	2006-02-15 05:09:17
697	152	1	2006-02-15 05:09:17
698	153	1	2006-02-15 05:09:17
699	153	1	2006-02-15 05:09:17
700	153	1	2006-02-15 05:09:17
701	153	1	2006-02-15 05:09:17
702	154	1	2006-02-15 05:09:17
703	154	1	2006-02-15 05:09:17
704	154	1	2006-02-15 05:09:17
705	154	2	2006-02-15 05:09:17
706	154	2	2006-02-15 05:09:17
707	154	2	2006-02-15 05:09:17
708	154	2	2006-02-15 05:09:17
709	155	1	2006-02-15 05:09:17
710	155	1	2006-02-15 05:09:17
711	155	2	2006-02-15 05:09:17
712	155	2	2006-02-15 05:09:17
713	155	2	2006-02-15 05:09:17
714	156	2	2006-02-15 05:09:17
715	156	2	2006-02-15 05:09:17
716	157	2	2006-02-15 05:09:17
717	157	2	2006-02-15 05:09:17
718	157	2	2006-02-15 05:09:17
719	158	1	2006-02-15 05:09:17
720	158	1	2006-02-15 05:09:17
721	158	2	2006-02-15 05:09:17
722	158	2	2006-02-15 05:09:17
723	158	2	2006-02-15 05:09:17
724	159	1	2006-02-15 05:09:17
725	159	1	2006-02-15 05:09:17
726	159	1	2006-02-15 05:09:17
727	159	1	2006-02-15 05:09:17
728	159	2	2006-02-15 05:09:17
729	159	2	2006-02-15 05:09:17
730	159	2	2006-02-15 05:09:17
731	160	1	2006-02-15 05:09:17
732	160	1	2006-02-15 05:09:17
733	160	2	2006-02-15 05:09:17
734	160	2	2006-02-15 05:09:17
735	160	2	2006-02-15 05:09:17
736	161	1	2006-02-15 05:09:17
737	161	1	2006-02-15 05:09:17
738	162	1	2006-02-15 05:09:17
739	162	1	2006-02-15 05:09:17
740	162	1	2006-02-15 05:09:17
741	162	2	2006-02-15 05:09:17
742	162	2	2006-02-15 05:09:17
743	162	2	2006-02-15 05:09:17
744	162	2	2006-02-15 05:09:17
745	163	2	2006-02-15 05:09:17
746	163	2	2006-02-15 05:09:17
747	163	2	2006-02-15 05:09:17
748	164	1	2006-02-15 05:09:17
749	164	1	2006-02-15 05:09:17
750	164	2	2006-02-15 05:09:17
751	164	2	2006-02-15 05:09:17
752	164	2	2006-02-15 05:09:17
753	165	1	2006-02-15 05:09:17
754	165	1	2006-02-15 05:09:17
755	165	1	2006-02-15 05:09:17
756	165	2	2006-02-15 05:09:17
757	165	2	2006-02-15 05:09:17
758	166	1	2006-02-15 05:09:17
759	166	1	2006-02-15 05:09:17
760	166	1	2006-02-15 05:09:17
761	166	1	2006-02-15 05:09:17
762	166	2	2006-02-15 05:09:17
763	166	2	2006-02-15 05:09:17
764	167	1	2006-02-15 05:09:17
765	167	1	2006-02-15 05:09:17
766	167	1	2006-02-15 05:09:17
767	167	1	2006-02-15 05:09:17
768	167	2	2006-02-15 05:09:17
769	167	2	2006-02-15 05:09:17
770	167	2	2006-02-15 05:09:17
771	168	1	2006-02-15 05:09:17
772	168	1	2006-02-15 05:09:17
773	169	1	2006-02-15 05:09:17
774	169	1	2006-02-15 05:09:17
775	169	2	2006-02-15 05:09:17
776	169	2	2006-02-15 05:09:17
777	170	1	2006-02-15 05:09:17
778	170	1	2006-02-15 05:09:17
779	170	2	2006-02-15 05:09:17
780	170	2	2006-02-15 05:09:17
781	170	2	2006-02-15 05:09:17
782	170	2	2006-02-15 05:09:17
783	172	1	2006-02-15 05:09:17
784	172	1	2006-02-15 05:09:17
785	172	1	2006-02-15 05:09:17
786	172	1	2006-02-15 05:09:17
787	172	2	2006-02-15 05:09:17
788	172	2	2006-02-15 05:09:17
789	172	2	2006-02-15 05:09:17
790	173	1	2006-02-15 05:09:17
791	173	1	2006-02-15 05:09:17
792	173	1	2006-02-15 05:09:17
793	173	2	2006-02-15 05:09:17
794	173	2	2006-02-15 05:09:17
795	174	1	2006-02-15 05:09:17
796	174	1	2006-02-15 05:09:17
797	174	1	2006-02-15 05:09:17
798	174	1	2006-02-15 05:09:17
799	174	2	2006-02-15 05:09:17
800	174	2	2006-02-15 05:09:17
801	174	2	2006-02-15 05:09:17
802	174	2	2006-02-15 05:09:17
803	175	1	2006-02-15 05:09:17
804	175	1	2006-02-15 05:09:17
805	175	2	2006-02-15 05:09:17
806	175	2	2006-02-15 05:09:17
807	175	2	2006-02-15 05:09:17
808	176	1	2006-02-15 05:09:17
809	176	1	2006-02-15 05:09:17
810	176	2	2006-02-15 05:09:17
811	176	2	2006-02-15 05:09:17
812	176	2	2006-02-15 05:09:17
813	176	2	2006-02-15 05:09:17
814	177	2	2006-02-15 05:09:17
815	177	2	2006-02-15 05:09:17
816	177	2	2006-02-15 05:09:17
817	178	1	2006-02-15 05:09:17
818	178	1	2006-02-15 05:09:17
819	179	1	2006-02-15 05:09:17
820	179	1	2006-02-15 05:09:17
821	179	1	2006-02-15 05:09:17
822	179	1	2006-02-15 05:09:17
823	180	2	2006-02-15 05:09:17
824	180	2	2006-02-15 05:09:17
825	181	1	2006-02-15 05:09:17
826	181	1	2006-02-15 05:09:17
827	181	1	2006-02-15 05:09:17
828	181	2	2006-02-15 05:09:17
829	181	2	2006-02-15 05:09:17
830	181	2	2006-02-15 05:09:17
831	181	2	2006-02-15 05:09:17
832	182	1	2006-02-15 05:09:17
833	182	1	2006-02-15 05:09:17
834	183	1	2006-02-15 05:09:17
835	183	1	2006-02-15 05:09:17
836	183	1	2006-02-15 05:09:17
837	183	2	2006-02-15 05:09:17
838	183	2	2006-02-15 05:09:17
839	183	2	2006-02-15 05:09:17
840	184	1	2006-02-15 05:09:17
841	184	1	2006-02-15 05:09:17
842	184	2	2006-02-15 05:09:17
843	184	2	2006-02-15 05:09:17
844	184	2	2006-02-15 05:09:17
845	185	1	2006-02-15 05:09:17
846	185	1	2006-02-15 05:09:17
847	186	1	2006-02-15 05:09:17
848	186	1	2006-02-15 05:09:17
849	186	2	2006-02-15 05:09:17
850	186	2	2006-02-15 05:09:17
851	187	2	2006-02-15 05:09:17
852	187	2	2006-02-15 05:09:17
853	187	2	2006-02-15 05:09:17
854	188	1	2006-02-15 05:09:17
855	188	1	2006-02-15 05:09:17
856	188	1	2006-02-15 05:09:17
857	189	1	2006-02-15 05:09:17
858	189	1	2006-02-15 05:09:17
859	189	2	2006-02-15 05:09:17
860	189	2	2006-02-15 05:09:17
861	189	2	2006-02-15 05:09:17
862	189	2	2006-02-15 05:09:17
863	190	2	2006-02-15 05:09:17
864	190	2	2006-02-15 05:09:17
865	190	2	2006-02-15 05:09:17
866	190	2	2006-02-15 05:09:17
867	191	1	2006-02-15 05:09:17
868	191	1	2006-02-15 05:09:17
869	191	1	2006-02-15 05:09:17
870	191	2	2006-02-15 05:09:17
871	191	2	2006-02-15 05:09:17
872	191	2	2006-02-15 05:09:17
873	193	1	2006-02-15 05:09:17
874	193	1	2006-02-15 05:09:17
875	193	1	2006-02-15 05:09:17
876	193	1	2006-02-15 05:09:17
877	193	2	2006-02-15 05:09:17
878	193	2	2006-02-15 05:09:17
879	193	2	2006-02-15 05:09:17
880	193	2	2006-02-15 05:09:17
881	194	1	2006-02-15 05:09:17
882	194	1	2006-02-15 05:09:17
883	194	2	2006-02-15 05:09:17
884	194	2	2006-02-15 05:09:17
885	196	1	2006-02-15 05:09:17
886	196	1	2006-02-15 05:09:17
887	197	1	2006-02-15 05:09:17
888	197	1	2006-02-15 05:09:17
889	199	1	2006-02-15 05:09:17
890	199	1	2006-02-15 05:09:17
891	199	1	2006-02-15 05:09:17
892	199	1	2006-02-15 05:09:17
893	199	2	2006-02-15 05:09:17
894	199	2	2006-02-15 05:09:17
895	199	2	2006-02-15 05:09:17
896	199	2	2006-02-15 05:09:17
897	200	1	2006-02-15 05:09:17
898	200	1	2006-02-15 05:09:17
899	200	1	2006-02-15 05:09:17
900	200	1	2006-02-15 05:09:17
901	200	2	2006-02-15 05:09:17
902	200	2	2006-02-15 05:09:17
903	200	2	2006-02-15 05:09:17
904	200	2	2006-02-15 05:09:17
905	201	1	2006-02-15 05:09:17
906	201	1	2006-02-15 05:09:17
907	201	1	2006-02-15 05:09:17
908	201	1	2006-02-15 05:09:17
909	202	1	2006-02-15 05:09:17
910	202	1	2006-02-15 05:09:17
911	202	1	2006-02-15 05:09:17
912	203	2	2006-02-15 05:09:17
913	203	2	2006-02-15 05:09:17
914	203	2	2006-02-15 05:09:17
915	203	2	2006-02-15 05:09:17
916	204	1	2006-02-15 05:09:17
917	204	1	2006-02-15 05:09:17
918	204	1	2006-02-15 05:09:17
919	204	1	2006-02-15 05:09:17
920	204	2	2006-02-15 05:09:17
921	204	2	2006-02-15 05:09:17
922	205	1	2006-02-15 05:09:17
923	205	1	2006-02-15 05:09:17
924	205	1	2006-02-15 05:09:17
925	205	1	2006-02-15 05:09:17
926	206	1	2006-02-15 05:09:17
927	206	1	2006-02-15 05:09:17
928	206	1	2006-02-15 05:09:17
929	206	1	2006-02-15 05:09:17
930	206	2	2006-02-15 05:09:17
931	206	2	2006-02-15 05:09:17
932	206	2	2006-02-15 05:09:17
933	206	2	2006-02-15 05:09:17
934	207	1	2006-02-15 05:09:17
935	207	1	2006-02-15 05:09:17
936	207	1	2006-02-15 05:09:17
937	207	1	2006-02-15 05:09:17
938	208	1	2006-02-15 05:09:17
939	208	1	2006-02-15 05:09:17
940	208	1	2006-02-15 05:09:17
941	209	1	2006-02-15 05:09:17
942	209	1	2006-02-15 05:09:17
943	209	1	2006-02-15 05:09:17
944	209	1	2006-02-15 05:09:17
945	210	2	2006-02-15 05:09:17
946	210	2	2006-02-15 05:09:17
947	210	2	2006-02-15 05:09:17
948	211	1	2006-02-15 05:09:17
949	211	1	2006-02-15 05:09:17
950	212	1	2006-02-15 05:09:17
951	212	1	2006-02-15 05:09:17
952	212	1	2006-02-15 05:09:17
953	212	2	2006-02-15 05:09:17
954	212	2	2006-02-15 05:09:17
955	213	1	2006-02-15 05:09:17
956	213	1	2006-02-15 05:09:17
957	213	1	2006-02-15 05:09:17
958	213	1	2006-02-15 05:09:17
959	214	2	2006-02-15 05:09:17
960	214	2	2006-02-15 05:09:17
961	214	2	2006-02-15 05:09:17
962	214	2	2006-02-15 05:09:17
963	215	1	2006-02-15 05:09:17
964	215	1	2006-02-15 05:09:17
965	215	1	2006-02-15 05:09:17
966	215	2	2006-02-15 05:09:17
967	215	2	2006-02-15 05:09:17
968	215	2	2006-02-15 05:09:17
969	216	1	2006-02-15 05:09:17
970	216	1	2006-02-15 05:09:17
971	216	2	2006-02-15 05:09:17
972	216	2	2006-02-15 05:09:17
973	216	2	2006-02-15 05:09:17
974	218	1	2006-02-15 05:09:17
975	218	1	2006-02-15 05:09:17
976	218	1	2006-02-15 05:09:17
977	218	1	2006-02-15 05:09:17
978	218	2	2006-02-15 05:09:17
979	218	2	2006-02-15 05:09:17
980	218	2	2006-02-15 05:09:17
981	219	1	2006-02-15 05:09:17
982	219	1	2006-02-15 05:09:17
983	219	1	2006-02-15 05:09:17
984	219	1	2006-02-15 05:09:17
985	220	1	2006-02-15 05:09:17
986	220	1	2006-02-15 05:09:17
987	220	1	2006-02-15 05:09:17
988	220	1	2006-02-15 05:09:17
989	220	2	2006-02-15 05:09:17
990	220	2	2006-02-15 05:09:17
991	220	2	2006-02-15 05:09:17
992	220	2	2006-02-15 05:09:17
993	222	1	2006-02-15 05:09:17
994	222	1	2006-02-15 05:09:17
995	222	2	2006-02-15 05:09:17
996	222	2	2006-02-15 05:09:17
997	222	2	2006-02-15 05:09:17
998	222	2	2006-02-15 05:09:17
999	223	2	2006-02-15 05:09:17
1000	223	2	2006-02-15 05:09:17
1001	224	1	2006-02-15 05:09:17
1002	224	1	2006-02-15 05:09:17
1003	225	1	2006-02-15 05:09:17
1004	225	1	2006-02-15 05:09:17
1005	225	1	2006-02-15 05:09:17
1006	226	1	2006-02-15 05:09:17
1007	226	1	2006-02-15 05:09:17
1008	226	2	2006-02-15 05:09:17
1009	226	2	2006-02-15 05:09:17
1010	226	2	2006-02-15 05:09:17
1011	227	1	2006-02-15 05:09:17
1012	227	1	2006-02-15 05:09:17
1013	227	1	2006-02-15 05:09:17
1014	227	2	2006-02-15 05:09:17
1015	227	2	2006-02-15 05:09:17
1016	228	1	2006-02-15 05:09:17
1017	228	1	2006-02-15 05:09:17
1018	228	1	2006-02-15 05:09:17
1019	228	2	2006-02-15 05:09:17
1020	228	2	2006-02-15 05:09:17
1021	228	2	2006-02-15 05:09:17
1022	228	2	2006-02-15 05:09:17
1023	229	1	2006-02-15 05:09:17
1024	229	1	2006-02-15 05:09:17
1025	229	2	2006-02-15 05:09:17
1026	229	2	2006-02-15 05:09:17
1027	230	1	2006-02-15 05:09:17
1028	230	1	2006-02-15 05:09:17
1029	231	1	2006-02-15 05:09:17
1030	231	1	2006-02-15 05:09:17
1031	231	1	2006-02-15 05:09:17
1032	231	1	2006-02-15 05:09:17
1033	231	2	2006-02-15 05:09:17
1034	231	2	2006-02-15 05:09:17
1035	231	2	2006-02-15 05:09:17
1036	231	2	2006-02-15 05:09:17
1037	232	1	2006-02-15 05:09:17
1038	232	1	2006-02-15 05:09:17
1039	232	1	2006-02-15 05:09:17
1040	232	2	2006-02-15 05:09:17
1041	232	2	2006-02-15 05:09:17
1042	233	1	2006-02-15 05:09:17
1043	233	1	2006-02-15 05:09:17
1044	233	1	2006-02-15 05:09:17
1045	233	1	2006-02-15 05:09:17
1046	233	2	2006-02-15 05:09:17
1047	233	2	2006-02-15 05:09:17
1048	234	1	2006-02-15 05:09:17
1049	234	1	2006-02-15 05:09:17
1050	234	1	2006-02-15 05:09:17
1051	234	1	2006-02-15 05:09:17
1052	234	2	2006-02-15 05:09:17
1053	234	2	2006-02-15 05:09:17
1054	234	2	2006-02-15 05:09:17
1055	235	1	2006-02-15 05:09:17
1056	235	1	2006-02-15 05:09:17
1057	235	2	2006-02-15 05:09:17
1058	235	2	2006-02-15 05:09:17
1059	235	2	2006-02-15 05:09:17
1060	235	2	2006-02-15 05:09:17
1061	236	2	2006-02-15 05:09:17
1062	236	2	2006-02-15 05:09:17
1063	236	2	2006-02-15 05:09:17
1064	236	2	2006-02-15 05:09:17
1065	237	1	2006-02-15 05:09:17
1066	237	1	2006-02-15 05:09:17
1067	238	1	2006-02-15 05:09:17
1068	238	1	2006-02-15 05:09:17
1069	239	1	2006-02-15 05:09:17
1070	239	1	2006-02-15 05:09:17
1071	239	1	2006-02-15 05:09:17
1072	239	1	2006-02-15 05:09:17
1073	239	2	2006-02-15 05:09:17
1074	239	2	2006-02-15 05:09:17
1075	239	2	2006-02-15 05:09:17
1076	239	2	2006-02-15 05:09:17
1077	240	2	2006-02-15 05:09:17
1078	240	2	2006-02-15 05:09:17
1079	240	2	2006-02-15 05:09:17
1080	241	1	2006-02-15 05:09:17
1081	241	1	2006-02-15 05:09:17
1082	241	1	2006-02-15 05:09:17
1083	241	1	2006-02-15 05:09:17
1084	242	1	2006-02-15 05:09:17
1085	242	1	2006-02-15 05:09:17
1086	242	2	2006-02-15 05:09:17
1087	242	2	2006-02-15 05:09:17
1088	242	2	2006-02-15 05:09:17
1089	243	1	2006-02-15 05:09:17
1090	243	1	2006-02-15 05:09:17
1091	243	2	2006-02-15 05:09:17
1092	243	2	2006-02-15 05:09:17
1093	243	2	2006-02-15 05:09:17
1094	243	2	2006-02-15 05:09:17
1095	244	1	2006-02-15 05:09:17
1096	244	1	2006-02-15 05:09:17
1097	244	1	2006-02-15 05:09:17
1098	244	1	2006-02-15 05:09:17
1099	244	2	2006-02-15 05:09:17
1100	244	2	2006-02-15 05:09:17
1101	244	2	2006-02-15 05:09:17
1102	245	1	2006-02-15 05:09:17
1103	245	1	2006-02-15 05:09:17
1104	245	1	2006-02-15 05:09:17
1105	245	2	2006-02-15 05:09:17
1106	245	2	2006-02-15 05:09:17
1107	245	2	2006-02-15 05:09:17
1108	245	2	2006-02-15 05:09:17
1109	246	2	2006-02-15 05:09:17
1110	246	2	2006-02-15 05:09:17
1111	246	2	2006-02-15 05:09:17
1112	247	1	2006-02-15 05:09:17
1113	247	1	2006-02-15 05:09:17
1114	247	1	2006-02-15 05:09:17
1115	247	2	2006-02-15 05:09:17
1116	247	2	2006-02-15 05:09:17
1117	247	2	2006-02-15 05:09:17
1118	247	2	2006-02-15 05:09:17
1119	248	2	2006-02-15 05:09:17
1120	248	2	2006-02-15 05:09:17
1121	249	1	2006-02-15 05:09:17
1122	249	1	2006-02-15 05:09:17
1123	249	2	2006-02-15 05:09:17
1124	249	2	2006-02-15 05:09:17
1125	249	2	2006-02-15 05:09:17
1126	249	2	2006-02-15 05:09:17
1127	250	2	2006-02-15 05:09:17
1128	250	2	2006-02-15 05:09:17
1129	250	2	2006-02-15 05:09:17
1130	250	2	2006-02-15 05:09:17
1131	251	1	2006-02-15 05:09:17
1132	251	1	2006-02-15 05:09:17
1133	251	2	2006-02-15 05:09:17
1134	251	2	2006-02-15 05:09:17
1135	251	2	2006-02-15 05:09:17
1136	252	1	2006-02-15 05:09:17
1137	252	1	2006-02-15 05:09:17
1138	252	1	2006-02-15 05:09:17
1139	252	2	2006-02-15 05:09:17
1140	252	2	2006-02-15 05:09:17
1141	252	2	2006-02-15 05:09:17
1142	253	1	2006-02-15 05:09:17
1143	253	1	2006-02-15 05:09:17
1144	253	1	2006-02-15 05:09:17
1145	253	1	2006-02-15 05:09:17
1146	253	2	2006-02-15 05:09:17
1147	253	2	2006-02-15 05:09:17
1148	254	1	2006-02-15 05:09:17
1149	254	1	2006-02-15 05:09:17
1150	254	2	2006-02-15 05:09:17
1151	254	2	2006-02-15 05:09:17
1152	254	2	2006-02-15 05:09:17
1153	255	1	2006-02-15 05:09:17
1154	255	1	2006-02-15 05:09:17
1155	255	1	2006-02-15 05:09:17
1156	255	1	2006-02-15 05:09:17
1157	255	2	2006-02-15 05:09:17
1158	255	2	2006-02-15 05:09:17
1159	256	2	2006-02-15 05:09:17
1160	256	2	2006-02-15 05:09:17
1161	256	2	2006-02-15 05:09:17
1162	257	2	2006-02-15 05:09:17
1163	257	2	2006-02-15 05:09:17
1164	257	2	2006-02-15 05:09:17
1165	258	2	2006-02-15 05:09:17
1166	258	2	2006-02-15 05:09:17
1167	258	2	2006-02-15 05:09:17
1168	258	2	2006-02-15 05:09:17
1169	259	1	2006-02-15 05:09:17
1170	259	1	2006-02-15 05:09:17
1171	260	2	2006-02-15 05:09:17
1172	260	2	2006-02-15 05:09:17
1173	260	2	2006-02-15 05:09:17
1174	260	2	2006-02-15 05:09:17
1175	261	1	2006-02-15 05:09:17
1176	261	1	2006-02-15 05:09:17
1177	262	2	2006-02-15 05:09:17
1178	262	2	2006-02-15 05:09:17
1179	263	1	2006-02-15 05:09:17
1180	263	1	2006-02-15 05:09:17
1181	263	1	2006-02-15 05:09:17
1182	263	1	2006-02-15 05:09:17
1183	263	2	2006-02-15 05:09:17
1184	263	2	2006-02-15 05:09:17
1185	263	2	2006-02-15 05:09:17
1186	264	2	2006-02-15 05:09:17
1187	264	2	2006-02-15 05:09:17
1188	265	1	2006-02-15 05:09:17
1189	265	1	2006-02-15 05:09:17
1190	265	1	2006-02-15 05:09:17
1191	265	1	2006-02-15 05:09:17
1192	266	1	2006-02-15 05:09:17
1193	266	1	2006-02-15 05:09:17
1194	266	1	2006-02-15 05:09:17
1195	266	1	2006-02-15 05:09:17
1196	266	2	2006-02-15 05:09:17
1197	266	2	2006-02-15 05:09:17
1198	266	2	2006-02-15 05:09:17
1199	266	2	2006-02-15 05:09:17
1200	267	1	2006-02-15 05:09:17
1201	267	1	2006-02-15 05:09:17
1202	267	1	2006-02-15 05:09:17
1203	267	1	2006-02-15 05:09:17
1204	267	2	2006-02-15 05:09:17
1205	267	2	2006-02-15 05:09:17
1206	268	2	2006-02-15 05:09:17
1207	268	2	2006-02-15 05:09:17
1208	269	1	2006-02-15 05:09:17
1209	269	1	2006-02-15 05:09:17
1210	269	2	2006-02-15 05:09:17
1211	269	2	2006-02-15 05:09:17
1212	269	2	2006-02-15 05:09:17
1213	269	2	2006-02-15 05:09:17
1214	270	1	2006-02-15 05:09:17
1215	270	1	2006-02-15 05:09:17
1216	270	1	2006-02-15 05:09:17
1217	270	2	2006-02-15 05:09:17
1218	270	2	2006-02-15 05:09:17
1219	270	2	2006-02-15 05:09:17
1220	270	2	2006-02-15 05:09:17
1221	271	1	2006-02-15 05:09:17
1222	271	1	2006-02-15 05:09:17
1223	271	1	2006-02-15 05:09:17
1224	271	2	2006-02-15 05:09:17
1225	271	2	2006-02-15 05:09:17
1226	272	1	2006-02-15 05:09:17
1227	272	1	2006-02-15 05:09:17
1228	272	1	2006-02-15 05:09:17
1229	272	1	2006-02-15 05:09:17
1230	273	1	2006-02-15 05:09:17
1231	273	1	2006-02-15 05:09:17
1232	273	1	2006-02-15 05:09:17
1233	273	1	2006-02-15 05:09:17
1234	273	2	2006-02-15 05:09:17
1235	273	2	2006-02-15 05:09:17
1236	273	2	2006-02-15 05:09:17
1237	274	1	2006-02-15 05:09:17
1238	274	1	2006-02-15 05:09:17
1239	274	1	2006-02-15 05:09:17
1240	274	2	2006-02-15 05:09:17
1241	274	2	2006-02-15 05:09:17
1242	274	2	2006-02-15 05:09:17
1243	274	2	2006-02-15 05:09:17
1244	275	1	2006-02-15 05:09:17
1245	275	1	2006-02-15 05:09:17
1246	275	1	2006-02-15 05:09:17
1247	275	2	2006-02-15 05:09:17
1248	275	2	2006-02-15 05:09:17
1249	276	1	2006-02-15 05:09:17
1250	276	1	2006-02-15 05:09:17
1251	276	1	2006-02-15 05:09:17
1252	276	1	2006-02-15 05:09:17
1253	277	1	2006-02-15 05:09:17
1254	277	1	2006-02-15 05:09:17
1255	277	1	2006-02-15 05:09:17
1256	278	1	2006-02-15 05:09:17
1257	278	1	2006-02-15 05:09:17
1258	279	1	2006-02-15 05:09:17
1259	279	1	2006-02-15 05:09:17
1260	280	1	2006-02-15 05:09:17
1261	280	1	2006-02-15 05:09:17
1262	280	1	2006-02-15 05:09:17
1263	280	1	2006-02-15 05:09:17
1264	280	2	2006-02-15 05:09:17
1265	280	2	2006-02-15 05:09:17
1266	281	1	2006-02-15 05:09:17
1267	281	1	2006-02-15 05:09:17
1268	281	2	2006-02-15 05:09:17
1269	281	2	2006-02-15 05:09:17
1270	281	2	2006-02-15 05:09:17
1271	281	2	2006-02-15 05:09:17
1272	282	1	2006-02-15 05:09:17
1273	282	1	2006-02-15 05:09:17
1274	282	1	2006-02-15 05:09:17
1275	282	2	2006-02-15 05:09:17
1276	282	2	2006-02-15 05:09:17
1277	282	2	2006-02-15 05:09:17
1278	283	1	2006-02-15 05:09:17
1279	283	1	2006-02-15 05:09:17
1280	283	1	2006-02-15 05:09:17
1281	284	1	2006-02-15 05:09:17
1282	284	1	2006-02-15 05:09:17
1283	284	1	2006-02-15 05:09:17
1284	284	2	2006-02-15 05:09:17
1285	284	2	2006-02-15 05:09:17
1286	284	2	2006-02-15 05:09:17
1287	284	2	2006-02-15 05:09:17
1288	285	1	2006-02-15 05:09:17
1289	285	1	2006-02-15 05:09:17
1290	285	1	2006-02-15 05:09:17
1291	285	2	2006-02-15 05:09:17
1292	285	2	2006-02-15 05:09:17
1293	285	2	2006-02-15 05:09:17
1294	285	2	2006-02-15 05:09:17
1295	286	1	2006-02-15 05:09:17
1296	286	1	2006-02-15 05:09:17
1297	286	2	2006-02-15 05:09:17
1298	286	2	2006-02-15 05:09:17
1299	286	2	2006-02-15 05:09:17
1300	287	1	2006-02-15 05:09:17
1301	287	1	2006-02-15 05:09:17
1302	287	2	2006-02-15 05:09:17
1303	287	2	2006-02-15 05:09:17
1304	288	1	2006-02-15 05:09:17
1305	288	1	2006-02-15 05:09:17
1306	288	2	2006-02-15 05:09:17
1307	288	2	2006-02-15 05:09:17
1308	288	2	2006-02-15 05:09:17
1309	288	2	2006-02-15 05:09:17
1310	289	1	2006-02-15 05:09:17
1311	289	1	2006-02-15 05:09:17
1312	290	1	2006-02-15 05:09:17
1313	290	1	2006-02-15 05:09:17
1314	290	1	2006-02-15 05:09:17
1315	291	1	2006-02-15 05:09:17
1316	291	1	2006-02-15 05:09:17
1317	291	1	2006-02-15 05:09:17
1318	291	1	2006-02-15 05:09:17
1319	292	1	2006-02-15 05:09:17
1320	292	1	2006-02-15 05:09:17
1321	292	1	2006-02-15 05:09:17
1322	292	2	2006-02-15 05:09:17
1323	292	2	2006-02-15 05:09:17
1324	292	2	2006-02-15 05:09:17
1325	293	1	2006-02-15 05:09:17
1326	293	1	2006-02-15 05:09:17
1327	293	2	2006-02-15 05:09:17
1328	293	2	2006-02-15 05:09:17
1329	293	2	2006-02-15 05:09:17
1330	294	1	2006-02-15 05:09:17
1331	294	1	2006-02-15 05:09:17
1332	294	2	2006-02-15 05:09:17
1333	294	2	2006-02-15 05:09:17
1334	294	2	2006-02-15 05:09:17
1335	295	1	2006-02-15 05:09:17
1336	295	1	2006-02-15 05:09:17
1337	295	1	2006-02-15 05:09:17
1338	295	1	2006-02-15 05:09:17
1339	295	2	2006-02-15 05:09:17
1340	295	2	2006-02-15 05:09:17
1341	295	2	2006-02-15 05:09:17
1342	295	2	2006-02-15 05:09:17
1343	296	1	2006-02-15 05:09:17
1344	296	1	2006-02-15 05:09:17
1345	296	1	2006-02-15 05:09:17
1346	296	1	2006-02-15 05:09:17
1347	297	2	2006-02-15 05:09:17
1348	297	2	2006-02-15 05:09:17
1349	298	1	2006-02-15 05:09:17
1350	298	1	2006-02-15 05:09:17
1351	298	2	2006-02-15 05:09:17
1352	298	2	2006-02-15 05:09:17
1353	298	2	2006-02-15 05:09:17
1354	299	1	2006-02-15 05:09:17
1355	299	1	2006-02-15 05:09:17
1356	299	1	2006-02-15 05:09:17
1357	299	1	2006-02-15 05:09:17
1358	300	1	2006-02-15 05:09:17
1359	300	1	2006-02-15 05:09:17
1360	300	2	2006-02-15 05:09:17
1361	300	2	2006-02-15 05:09:17
1362	300	2	2006-02-15 05:09:17
1363	300	2	2006-02-15 05:09:17
1364	301	1	2006-02-15 05:09:17
1365	301	1	2006-02-15 05:09:17
1366	301	1	2006-02-15 05:09:17
1367	301	1	2006-02-15 05:09:17
1368	301	2	2006-02-15 05:09:17
1369	301	2	2006-02-15 05:09:17
1370	301	2	2006-02-15 05:09:17
1371	301	2	2006-02-15 05:09:17
1372	302	1	2006-02-15 05:09:17
1373	302	1	2006-02-15 05:09:17
1374	302	2	2006-02-15 05:09:17
1375	302	2	2006-02-15 05:09:17
1376	302	2	2006-02-15 05:09:17
1377	302	2	2006-02-15 05:09:17
1378	303	1	2006-02-15 05:09:17
1379	303	1	2006-02-15 05:09:17
1380	303	1	2006-02-15 05:09:17
1381	303	1	2006-02-15 05:09:17
1382	303	2	2006-02-15 05:09:17
1383	303	2	2006-02-15 05:09:17
1384	304	1	2006-02-15 05:09:17
1385	304	1	2006-02-15 05:09:17
1386	304	1	2006-02-15 05:09:17
1387	304	1	2006-02-15 05:09:17
1388	304	2	2006-02-15 05:09:17
1389	304	2	2006-02-15 05:09:17
1390	305	1	2006-02-15 05:09:17
1391	305	1	2006-02-15 05:09:17
1392	305	1	2006-02-15 05:09:17
1393	305	1	2006-02-15 05:09:17
1394	305	2	2006-02-15 05:09:17
1395	305	2	2006-02-15 05:09:17
1396	305	2	2006-02-15 05:09:17
1397	306	1	2006-02-15 05:09:17
1398	306	1	2006-02-15 05:09:17
1399	306	1	2006-02-15 05:09:17
1400	307	1	2006-02-15 05:09:17
1401	307	1	2006-02-15 05:09:17
1402	307	1	2006-02-15 05:09:17
1403	307	2	2006-02-15 05:09:17
1404	307	2	2006-02-15 05:09:17
1405	307	2	2006-02-15 05:09:17
1406	308	1	2006-02-15 05:09:17
1407	308	1	2006-02-15 05:09:17
1408	308	2	2006-02-15 05:09:17
1409	308	2	2006-02-15 05:09:17
1410	309	1	2006-02-15 05:09:17
1411	309	1	2006-02-15 05:09:17
1412	309	2	2006-02-15 05:09:17
1413	309	2	2006-02-15 05:09:17
1414	309	2	2006-02-15 05:09:17
1415	309	2	2006-02-15 05:09:17
1416	310	1	2006-02-15 05:09:17
1417	310	1	2006-02-15 05:09:17
1418	311	1	2006-02-15 05:09:17
1419	311	1	2006-02-15 05:09:17
1420	311	1	2006-02-15 05:09:17
1421	311	2	2006-02-15 05:09:17
1422	311	2	2006-02-15 05:09:17
1423	311	2	2006-02-15 05:09:17
1424	311	2	2006-02-15 05:09:17
1425	312	2	2006-02-15 05:09:17
1426	312	2	2006-02-15 05:09:17
1427	312	2	2006-02-15 05:09:17
1428	313	1	2006-02-15 05:09:17
1429	313	1	2006-02-15 05:09:17
1430	313	1	2006-02-15 05:09:17
1431	313	1	2006-02-15 05:09:17
1432	313	2	2006-02-15 05:09:17
1433	313	2	2006-02-15 05:09:17
1434	314	1	2006-02-15 05:09:17
1435	314	1	2006-02-15 05:09:17
1436	314	2	2006-02-15 05:09:17
1437	314	2	2006-02-15 05:09:17
1438	314	2	2006-02-15 05:09:17
1439	314	2	2006-02-15 05:09:17
1440	315	2	2006-02-15 05:09:17
1441	315	2	2006-02-15 05:09:17
1442	315	2	2006-02-15 05:09:17
1443	316	2	2006-02-15 05:09:17
1444	316	2	2006-02-15 05:09:17
1445	317	1	2006-02-15 05:09:17
1446	317	1	2006-02-15 05:09:17
1447	317	1	2006-02-15 05:09:17
1448	317	1	2006-02-15 05:09:17
1449	317	2	2006-02-15 05:09:17
1450	317	2	2006-02-15 05:09:17
1451	317	2	2006-02-15 05:09:17
1452	319	1	2006-02-15 05:09:17
1453	319	1	2006-02-15 05:09:17
1454	319	1	2006-02-15 05:09:17
1455	319	2	2006-02-15 05:09:17
1456	319	2	2006-02-15 05:09:17
1457	319	2	2006-02-15 05:09:17
1458	319	2	2006-02-15 05:09:17
1459	320	1	2006-02-15 05:09:17
1460	320	1	2006-02-15 05:09:17
1461	320	1	2006-02-15 05:09:17
1462	320	2	2006-02-15 05:09:17
1463	320	2	2006-02-15 05:09:17
1464	320	2	2006-02-15 05:09:17
1465	320	2	2006-02-15 05:09:17
1466	321	1	2006-02-15 05:09:17
1467	321	1	2006-02-15 05:09:17
1468	321	1	2006-02-15 05:09:17
1469	321	1	2006-02-15 05:09:17
1470	322	1	2006-02-15 05:09:17
1471	322	1	2006-02-15 05:09:17
1472	322	1	2006-02-15 05:09:17
1473	322	1	2006-02-15 05:09:17
1474	322	2	2006-02-15 05:09:17
1475	322	2	2006-02-15 05:09:17
1476	323	2	2006-02-15 05:09:17
1477	323	2	2006-02-15 05:09:17
1478	323	2	2006-02-15 05:09:17
1479	323	2	2006-02-15 05:09:17
1480	324	1	2006-02-15 05:09:17
1481	324	1	2006-02-15 05:09:17
1482	324	1	2006-02-15 05:09:17
1483	324	2	2006-02-15 05:09:17
1484	324	2	2006-02-15 05:09:17
1485	326	1	2006-02-15 05:09:17
1486	326	1	2006-02-15 05:09:17
1487	326	2	2006-02-15 05:09:17
1488	326	2	2006-02-15 05:09:17
1489	326	2	2006-02-15 05:09:17
1490	326	2	2006-02-15 05:09:17
1491	327	1	2006-02-15 05:09:17
1492	327	1	2006-02-15 05:09:17
1493	327	1	2006-02-15 05:09:17
1494	327	1	2006-02-15 05:09:17
1495	327	2	2006-02-15 05:09:17
1496	327	2	2006-02-15 05:09:17
1497	328	2	2006-02-15 05:09:17
1498	328	2	2006-02-15 05:09:17
1499	328	2	2006-02-15 05:09:17
1500	328	2	2006-02-15 05:09:17
1501	329	1	2006-02-15 05:09:17
1502	329	1	2006-02-15 05:09:17
1503	329	1	2006-02-15 05:09:17
1504	329	2	2006-02-15 05:09:17
1505	329	2	2006-02-15 05:09:17
1506	329	2	2006-02-15 05:09:17
1507	330	1	2006-02-15 05:09:17
1508	330	1	2006-02-15 05:09:17
1509	330	1	2006-02-15 05:09:17
1510	330	1	2006-02-15 05:09:17
1511	330	2	2006-02-15 05:09:17
1512	330	2	2006-02-15 05:09:17
1513	330	2	2006-02-15 05:09:17
1514	331	1	2006-02-15 05:09:17
1515	331	1	2006-02-15 05:09:17
1516	331	1	2006-02-15 05:09:17
1517	331	1	2006-02-15 05:09:17
1518	331	2	2006-02-15 05:09:17
1519	331	2	2006-02-15 05:09:17
1520	331	2	2006-02-15 05:09:17
1521	331	2	2006-02-15 05:09:17
1522	333	1	2006-02-15 05:09:17
1523	333	1	2006-02-15 05:09:17
1524	333	2	2006-02-15 05:09:17
1525	333	2	2006-02-15 05:09:17
1526	334	1	2006-02-15 05:09:17
1527	334	1	2006-02-15 05:09:17
1528	334	2	2006-02-15 05:09:17
1529	334	2	2006-02-15 05:09:17
1530	334	2	2006-02-15 05:09:17
1531	334	2	2006-02-15 05:09:17
1532	335	1	2006-02-15 05:09:17
1533	335	1	2006-02-15 05:09:17
1534	336	1	2006-02-15 05:09:17
1535	336	1	2006-02-15 05:09:17
1536	336	1	2006-02-15 05:09:17
1537	336	2	2006-02-15 05:09:17
1538	336	2	2006-02-15 05:09:17
1539	337	1	2006-02-15 05:09:17
1540	337	1	2006-02-15 05:09:17
1541	337	2	2006-02-15 05:09:17
1542	337	2	2006-02-15 05:09:17
1543	338	2	2006-02-15 05:09:17
1544	338	2	2006-02-15 05:09:17
1545	338	2	2006-02-15 05:09:17
1546	339	2	2006-02-15 05:09:17
1547	339	2	2006-02-15 05:09:17
1548	339	2	2006-02-15 05:09:17
1549	340	1	2006-02-15 05:09:17
1550	340	1	2006-02-15 05:09:17
1551	341	1	2006-02-15 05:09:17
1552	341	1	2006-02-15 05:09:17
1553	341	1	2006-02-15 05:09:17
1554	341	1	2006-02-15 05:09:17
1555	341	2	2006-02-15 05:09:17
1556	341	2	2006-02-15 05:09:17
1557	341	2	2006-02-15 05:09:17
1558	341	2	2006-02-15 05:09:17
1559	342	1	2006-02-15 05:09:17
1560	342	1	2006-02-15 05:09:17
1561	342	1	2006-02-15 05:09:17
1562	342	1	2006-02-15 05:09:17
1563	343	1	2006-02-15 05:09:17
1564	343	1	2006-02-15 05:09:17
1565	344	1	2006-02-15 05:09:17
1566	344	1	2006-02-15 05:09:17
1567	344	1	2006-02-15 05:09:17
1568	344	2	2006-02-15 05:09:17
1569	344	2	2006-02-15 05:09:17
1570	345	1	2006-02-15 05:09:17
1571	345	1	2006-02-15 05:09:17
1572	345	1	2006-02-15 05:09:17
1573	345	2	2006-02-15 05:09:17
1574	345	2	2006-02-15 05:09:17
1575	346	1	2006-02-15 05:09:17
1576	346	1	2006-02-15 05:09:17
1577	346	2	2006-02-15 05:09:17
1578	346	2	2006-02-15 05:09:17
1579	346	2	2006-02-15 05:09:17
1580	346	2	2006-02-15 05:09:17
1581	347	1	2006-02-15 05:09:17
1582	347	1	2006-02-15 05:09:17
1583	347	1	2006-02-15 05:09:17
1584	347	1	2006-02-15 05:09:17
1585	348	2	2006-02-15 05:09:17
1586	348	2	2006-02-15 05:09:17
1587	348	2	2006-02-15 05:09:17
1588	348	2	2006-02-15 05:09:17
1589	349	1	2006-02-15 05:09:17
1590	349	1	2006-02-15 05:09:17
1591	349	1	2006-02-15 05:09:17
1592	349	1	2006-02-15 05:09:17
1593	349	2	2006-02-15 05:09:17
1594	349	2	2006-02-15 05:09:17
1595	349	2	2006-02-15 05:09:17
1596	350	1	2006-02-15 05:09:17
1597	350	1	2006-02-15 05:09:17
1598	350	1	2006-02-15 05:09:17
1599	350	1	2006-02-15 05:09:17
1600	350	2	2006-02-15 05:09:17
1601	350	2	2006-02-15 05:09:17
1602	350	2	2006-02-15 05:09:17
1603	350	2	2006-02-15 05:09:17
1604	351	1	2006-02-15 05:09:17
1605	351	1	2006-02-15 05:09:17
1606	351	1	2006-02-15 05:09:17
1607	351	2	2006-02-15 05:09:17
1608	351	2	2006-02-15 05:09:17
1609	351	2	2006-02-15 05:09:17
1610	352	2	2006-02-15 05:09:17
1611	352	2	2006-02-15 05:09:17
1612	352	2	2006-02-15 05:09:17
1613	352	2	2006-02-15 05:09:17
1614	353	1	2006-02-15 05:09:17
1615	353	1	2006-02-15 05:09:17
1616	353	2	2006-02-15 05:09:17
1617	353	2	2006-02-15 05:09:17
1618	353	2	2006-02-15 05:09:17
1619	353	2	2006-02-15 05:09:17
1620	354	1	2006-02-15 05:09:17
1621	354	1	2006-02-15 05:09:17
1622	354	1	2006-02-15 05:09:17
1623	354	2	2006-02-15 05:09:17
1624	354	2	2006-02-15 05:09:17
1625	355	2	2006-02-15 05:09:17
1626	355	2	2006-02-15 05:09:17
1627	356	1	2006-02-15 05:09:17
1628	356	1	2006-02-15 05:09:17
1629	356	1	2006-02-15 05:09:17
1630	356	1	2006-02-15 05:09:17
1631	356	2	2006-02-15 05:09:17
1632	356	2	2006-02-15 05:09:17
1633	356	2	2006-02-15 05:09:17
1634	356	2	2006-02-15 05:09:17
1635	357	2	2006-02-15 05:09:17
1636	357	2	2006-02-15 05:09:17
1637	357	2	2006-02-15 05:09:17
1638	357	2	2006-02-15 05:09:17
1639	358	1	2006-02-15 05:09:17
1640	358	1	2006-02-15 05:09:17
1641	358	1	2006-02-15 05:09:17
1642	358	1	2006-02-15 05:09:17
1643	358	2	2006-02-15 05:09:17
1644	358	2	2006-02-15 05:09:17
1645	358	2	2006-02-15 05:09:17
1646	358	2	2006-02-15 05:09:17
1647	360	1	2006-02-15 05:09:17
1648	360	1	2006-02-15 05:09:17
1649	360	1	2006-02-15 05:09:17
1650	360	1	2006-02-15 05:09:17
1651	361	1	2006-02-15 05:09:17
1652	361	1	2006-02-15 05:09:17
1653	361	1	2006-02-15 05:09:17
1654	361	1	2006-02-15 05:09:17
1655	361	2	2006-02-15 05:09:17
1656	361	2	2006-02-15 05:09:17
1657	361	2	2006-02-15 05:09:17
1658	361	2	2006-02-15 05:09:17
1659	362	1	2006-02-15 05:09:17
1660	362	1	2006-02-15 05:09:17
1661	363	1	2006-02-15 05:09:17
1662	363	1	2006-02-15 05:09:17
1663	363	1	2006-02-15 05:09:17
1664	363	2	2006-02-15 05:09:17
1665	363	2	2006-02-15 05:09:17
1666	363	2	2006-02-15 05:09:17
1667	364	1	2006-02-15 05:09:17
1668	364	1	2006-02-15 05:09:17
1669	364	1	2006-02-15 05:09:17
1670	365	1	2006-02-15 05:09:17
1671	365	1	2006-02-15 05:09:17
1672	365	2	2006-02-15 05:09:17
1673	365	2	2006-02-15 05:09:17
1674	366	1	2006-02-15 05:09:17
1675	366	1	2006-02-15 05:09:17
1676	366	1	2006-02-15 05:09:17
1677	366	1	2006-02-15 05:09:17
1678	366	2	2006-02-15 05:09:17
1679	366	2	2006-02-15 05:09:17
1680	366	2	2006-02-15 05:09:17
1681	367	1	2006-02-15 05:09:17
1682	367	1	2006-02-15 05:09:17
1683	367	1	2006-02-15 05:09:17
1684	367	1	2006-02-15 05:09:17
1685	367	2	2006-02-15 05:09:17
1686	367	2	2006-02-15 05:09:17
1687	367	2	2006-02-15 05:09:17
1688	368	1	2006-02-15 05:09:17
1689	368	1	2006-02-15 05:09:17
1690	369	1	2006-02-15 05:09:17
1691	369	1	2006-02-15 05:09:17
1692	369	1	2006-02-15 05:09:17
1693	369	1	2006-02-15 05:09:17
1694	369	2	2006-02-15 05:09:17
1695	369	2	2006-02-15 05:09:17
1696	369	2	2006-02-15 05:09:17
1697	369	2	2006-02-15 05:09:17
1698	370	1	2006-02-15 05:09:17
1699	370	1	2006-02-15 05:09:17
1700	370	1	2006-02-15 05:09:17
1701	370	2	2006-02-15 05:09:17
1702	370	2	2006-02-15 05:09:17
1703	371	1	2006-02-15 05:09:17
1704	371	1	2006-02-15 05:09:17
1705	371	1	2006-02-15 05:09:17
1706	372	1	2006-02-15 05:09:17
1707	372	1	2006-02-15 05:09:17
1708	373	1	2006-02-15 05:09:17
1709	373	1	2006-02-15 05:09:17
1710	373	1	2006-02-15 05:09:17
1711	373	2	2006-02-15 05:09:17
1712	373	2	2006-02-15 05:09:17
1713	374	1	2006-02-15 05:09:17
1714	374	1	2006-02-15 05:09:17
1715	374	1	2006-02-15 05:09:17
1716	374	2	2006-02-15 05:09:17
1717	374	2	2006-02-15 05:09:17
1718	374	2	2006-02-15 05:09:17
1719	374	2	2006-02-15 05:09:17
1720	375	1	2006-02-15 05:09:17
1721	375	1	2006-02-15 05:09:17
1722	376	1	2006-02-15 05:09:17
1723	376	1	2006-02-15 05:09:17
1724	376	1	2006-02-15 05:09:17
1725	376	1	2006-02-15 05:09:17
1726	376	2	2006-02-15 05:09:17
1727	376	2	2006-02-15 05:09:17
1728	376	2	2006-02-15 05:09:17
1729	377	1	2006-02-15 05:09:17
1730	377	1	2006-02-15 05:09:17
1731	377	1	2006-02-15 05:09:17
1732	377	2	2006-02-15 05:09:17
1733	377	2	2006-02-15 05:09:17
1734	377	2	2006-02-15 05:09:17
1735	378	1	2006-02-15 05:09:17
1736	378	1	2006-02-15 05:09:17
1737	378	1	2006-02-15 05:09:17
1738	378	1	2006-02-15 05:09:17
1739	378	2	2006-02-15 05:09:17
1740	378	2	2006-02-15 05:09:17
1741	378	2	2006-02-15 05:09:17
1742	378	2	2006-02-15 05:09:17
1743	379	2	2006-02-15 05:09:17
1744	379	2	2006-02-15 05:09:17
1745	379	2	2006-02-15 05:09:17
1746	379	2	2006-02-15 05:09:17
1747	380	1	2006-02-15 05:09:17
1748	380	1	2006-02-15 05:09:17
1749	380	2	2006-02-15 05:09:17
1750	380	2	2006-02-15 05:09:17
1751	380	2	2006-02-15 05:09:17
1752	381	1	2006-02-15 05:09:17
1753	381	1	2006-02-15 05:09:17
1754	381	2	2006-02-15 05:09:17
1755	381	2	2006-02-15 05:09:17
1756	381	2	2006-02-15 05:09:17
1757	382	1	2006-02-15 05:09:17
1758	382	1	2006-02-15 05:09:17
1759	382	1	2006-02-15 05:09:17
1760	382	1	2006-02-15 05:09:17
1761	382	2	2006-02-15 05:09:17
1762	382	2	2006-02-15 05:09:17
1763	382	2	2006-02-15 05:09:17
1764	382	2	2006-02-15 05:09:17
1765	383	1	2006-02-15 05:09:17
1766	383	1	2006-02-15 05:09:17
1767	383	1	2006-02-15 05:09:17
1768	383	2	2006-02-15 05:09:17
1769	383	2	2006-02-15 05:09:17
1770	384	2	2006-02-15 05:09:17
1771	384	2	2006-02-15 05:09:17
1772	384	2	2006-02-15 05:09:17
1773	385	1	2006-02-15 05:09:17
1774	385	1	2006-02-15 05:09:17
1775	385	2	2006-02-15 05:09:17
1776	385	2	2006-02-15 05:09:17
1777	385	2	2006-02-15 05:09:17
1778	387	1	2006-02-15 05:09:17
1779	387	1	2006-02-15 05:09:17
1780	387	1	2006-02-15 05:09:17
1781	387	2	2006-02-15 05:09:17
1782	387	2	2006-02-15 05:09:17
1783	387	2	2006-02-15 05:09:17
1784	388	1	2006-02-15 05:09:17
1785	388	1	2006-02-15 05:09:17
1786	388	1	2006-02-15 05:09:17
1787	388	2	2006-02-15 05:09:17
1788	388	2	2006-02-15 05:09:17
1789	388	2	2006-02-15 05:09:17
1790	389	1	2006-02-15 05:09:17
1791	389	1	2006-02-15 05:09:17
1792	389	2	2006-02-15 05:09:17
1793	389	2	2006-02-15 05:09:17
1794	390	1	2006-02-15 05:09:17
1795	390	1	2006-02-15 05:09:17
1796	390	1	2006-02-15 05:09:17
1797	391	1	2006-02-15 05:09:17
1798	391	1	2006-02-15 05:09:17
1799	391	1	2006-02-15 05:09:17
1800	391	1	2006-02-15 05:09:17
1801	391	2	2006-02-15 05:09:17
1802	391	2	2006-02-15 05:09:17
1803	391	2	2006-02-15 05:09:17
1804	392	1	2006-02-15 05:09:17
1805	392	1	2006-02-15 05:09:17
1806	392	1	2006-02-15 05:09:17
1807	392	1	2006-02-15 05:09:17
1808	392	2	2006-02-15 05:09:17
1809	392	2	2006-02-15 05:09:17
1810	393	1	2006-02-15 05:09:17
1811	393	1	2006-02-15 05:09:17
1812	394	1	2006-02-15 05:09:17
1813	394	1	2006-02-15 05:09:17
1814	394	1	2006-02-15 05:09:17
1815	394	1	2006-02-15 05:09:17
1816	395	1	2006-02-15 05:09:17
1817	395	1	2006-02-15 05:09:17
1818	395	1	2006-02-15 05:09:17
1819	395	2	2006-02-15 05:09:17
1820	395	2	2006-02-15 05:09:17
1821	395	2	2006-02-15 05:09:17
1822	396	2	2006-02-15 05:09:17
1823	396	2	2006-02-15 05:09:17
1824	396	2	2006-02-15 05:09:17
1825	396	2	2006-02-15 05:09:17
1826	397	1	2006-02-15 05:09:17
1827	397	1	2006-02-15 05:09:17
1828	397	1	2006-02-15 05:09:17
1829	397	2	2006-02-15 05:09:17
1830	397	2	2006-02-15 05:09:17
1831	397	2	2006-02-15 05:09:17
1832	397	2	2006-02-15 05:09:17
1833	398	2	2006-02-15 05:09:17
1834	398	2	2006-02-15 05:09:17
1835	398	2	2006-02-15 05:09:17
1836	398	2	2006-02-15 05:09:17
1837	399	2	2006-02-15 05:09:17
1838	399	2	2006-02-15 05:09:17
1839	400	1	2006-02-15 05:09:17
1840	400	1	2006-02-15 05:09:17
1841	401	1	2006-02-15 05:09:17
1842	401	1	2006-02-15 05:09:17
1843	402	1	2006-02-15 05:09:17
1844	402	1	2006-02-15 05:09:17
1845	402	1	2006-02-15 05:09:17
1846	402	2	2006-02-15 05:09:17
1847	402	2	2006-02-15 05:09:17
1848	402	2	2006-02-15 05:09:17
1849	403	1	2006-02-15 05:09:17
1850	403	1	2006-02-15 05:09:17
1851	403	1	2006-02-15 05:09:17
1852	403	1	2006-02-15 05:09:17
1853	403	2	2006-02-15 05:09:17
1854	403	2	2006-02-15 05:09:17
1855	403	2	2006-02-15 05:09:17
1856	403	2	2006-02-15 05:09:17
1857	405	2	2006-02-15 05:09:17
1858	405	2	2006-02-15 05:09:17
1859	406	1	2006-02-15 05:09:17
1860	406	1	2006-02-15 05:09:17
1861	406	2	2006-02-15 05:09:17
1862	406	2	2006-02-15 05:09:17
1863	406	2	2006-02-15 05:09:17
1864	406	2	2006-02-15 05:09:17
1865	407	1	2006-02-15 05:09:17
1866	407	1	2006-02-15 05:09:17
1867	408	1	2006-02-15 05:09:17
1868	408	1	2006-02-15 05:09:17
1869	408	1	2006-02-15 05:09:17
1870	408	1	2006-02-15 05:09:17
1871	408	2	2006-02-15 05:09:17
1872	408	2	2006-02-15 05:09:17
1873	408	2	2006-02-15 05:09:17
1874	409	1	2006-02-15 05:09:17
1875	409	1	2006-02-15 05:09:17
1876	409	1	2006-02-15 05:09:17
1877	409	1	2006-02-15 05:09:17
1878	409	2	2006-02-15 05:09:17
1879	409	2	2006-02-15 05:09:17
1880	409	2	2006-02-15 05:09:17
1881	410	1	2006-02-15 05:09:17
1882	410	1	2006-02-15 05:09:17
1883	410	1	2006-02-15 05:09:17
1884	410	2	2006-02-15 05:09:17
1885	410	2	2006-02-15 05:09:17
1886	411	1	2006-02-15 05:09:17
1887	411	1	2006-02-15 05:09:17
1888	412	1	2006-02-15 05:09:17
1889	412	1	2006-02-15 05:09:17
1890	412	1	2006-02-15 05:09:17
1891	412	1	2006-02-15 05:09:17
1892	412	2	2006-02-15 05:09:17
1893	412	2	2006-02-15 05:09:17
1894	412	2	2006-02-15 05:09:17
1895	412	2	2006-02-15 05:09:17
1896	413	1	2006-02-15 05:09:17
1897	413	1	2006-02-15 05:09:17
1898	413	1	2006-02-15 05:09:17
1899	414	1	2006-02-15 05:09:17
1900	414	1	2006-02-15 05:09:17
1901	414	1	2006-02-15 05:09:17
1902	414	2	2006-02-15 05:09:17
1903	414	2	2006-02-15 05:09:17
1904	414	2	2006-02-15 05:09:17
1905	415	1	2006-02-15 05:09:17
1906	415	1	2006-02-15 05:09:17
1907	415	1	2006-02-15 05:09:17
1908	415	2	2006-02-15 05:09:17
1909	415	2	2006-02-15 05:09:17
1910	415	2	2006-02-15 05:09:17
1911	416	1	2006-02-15 05:09:17
1912	416	1	2006-02-15 05:09:17
1913	416	2	2006-02-15 05:09:17
1914	416	2	2006-02-15 05:09:17
1915	416	2	2006-02-15 05:09:17
1916	416	2	2006-02-15 05:09:17
1917	417	1	2006-02-15 05:09:17
1918	417	1	2006-02-15 05:09:17
1919	417	1	2006-02-15 05:09:17
1920	417	1	2006-02-15 05:09:17
1921	417	2	2006-02-15 05:09:17
1922	417	2	2006-02-15 05:09:17
1923	418	1	2006-02-15 05:09:17
1924	418	1	2006-02-15 05:09:17
1925	418	1	2006-02-15 05:09:17
1926	418	1	2006-02-15 05:09:17
1927	418	2	2006-02-15 05:09:17
1928	418	2	2006-02-15 05:09:17
1929	418	2	2006-02-15 05:09:17
1930	418	2	2006-02-15 05:09:17
1931	420	1	2006-02-15 05:09:17
1932	420	1	2006-02-15 05:09:17
1933	420	2	2006-02-15 05:09:17
1934	420	2	2006-02-15 05:09:17
1935	420	2	2006-02-15 05:09:17
1936	421	2	2006-02-15 05:09:17
1937	421	2	2006-02-15 05:09:17
1938	421	2	2006-02-15 05:09:17
1939	421	2	2006-02-15 05:09:17
1940	422	2	2006-02-15 05:09:17
1941	422	2	2006-02-15 05:09:17
1942	423	1	2006-02-15 05:09:17
1943	423	1	2006-02-15 05:09:17
1944	423	2	2006-02-15 05:09:17
1945	423	2	2006-02-15 05:09:17
1946	424	1	2006-02-15 05:09:17
1947	424	1	2006-02-15 05:09:17
1948	424	1	2006-02-15 05:09:17
1949	424	2	2006-02-15 05:09:17
1950	424	2	2006-02-15 05:09:17
1951	425	2	2006-02-15 05:09:17
1952	425	2	2006-02-15 05:09:17
1953	426	2	2006-02-15 05:09:17
1954	426	2	2006-02-15 05:09:17
1955	426	2	2006-02-15 05:09:17
1956	427	1	2006-02-15 05:09:17
1957	427	1	2006-02-15 05:09:17
1958	427	1	2006-02-15 05:09:17
1959	427	1	2006-02-15 05:09:17
1960	428	1	2006-02-15 05:09:17
1961	428	1	2006-02-15 05:09:17
1962	428	1	2006-02-15 05:09:17
1963	428	1	2006-02-15 05:09:17
1964	428	2	2006-02-15 05:09:17
1965	428	2	2006-02-15 05:09:17
1966	429	1	2006-02-15 05:09:17
1967	429	1	2006-02-15 05:09:17
1968	429	2	2006-02-15 05:09:17
1969	429	2	2006-02-15 05:09:17
1970	429	2	2006-02-15 05:09:17
1971	429	2	2006-02-15 05:09:17
1972	430	2	2006-02-15 05:09:17
1973	430	2	2006-02-15 05:09:17
1974	430	2	2006-02-15 05:09:17
1975	430	2	2006-02-15 05:09:17
1976	431	2	2006-02-15 05:09:17
1977	431	2	2006-02-15 05:09:17
1978	431	2	2006-02-15 05:09:17
1979	432	1	2006-02-15 05:09:17
1980	432	1	2006-02-15 05:09:17
1981	432	1	2006-02-15 05:09:17
1982	432	2	2006-02-15 05:09:17
1983	432	2	2006-02-15 05:09:17
1984	433	1	2006-02-15 05:09:17
1985	433	1	2006-02-15 05:09:17
1986	433	1	2006-02-15 05:09:17
1987	433	1	2006-02-15 05:09:17
1988	433	2	2006-02-15 05:09:17
1989	433	2	2006-02-15 05:09:17
1990	434	1	2006-02-15 05:09:17
1991	434	1	2006-02-15 05:09:17
1992	434	1	2006-02-15 05:09:17
1993	434	1	2006-02-15 05:09:17
1994	434	2	2006-02-15 05:09:17
1995	434	2	2006-02-15 05:09:17
1996	434	2	2006-02-15 05:09:17
1997	434	2	2006-02-15 05:09:17
1998	435	1	2006-02-15 05:09:17
1999	435	1	2006-02-15 05:09:17
2000	436	1	2006-02-15 05:09:17
2001	436	1	2006-02-15 05:09:17
2002	436	1	2006-02-15 05:09:17
2003	436	2	2006-02-15 05:09:17
2004	436	2	2006-02-15 05:09:17
2005	436	2	2006-02-15 05:09:17
2006	437	1	2006-02-15 05:09:17
2007	437	1	2006-02-15 05:09:17
2008	437	2	2006-02-15 05:09:17
2009	437	2	2006-02-15 05:09:17
2010	437	2	2006-02-15 05:09:17
2011	437	2	2006-02-15 05:09:17
2012	438	1	2006-02-15 05:09:17
2013	438	1	2006-02-15 05:09:17
2014	438	2	2006-02-15 05:09:17
2015	438	2	2006-02-15 05:09:17
2016	438	2	2006-02-15 05:09:17
2017	439	1	2006-02-15 05:09:17
2018	439	1	2006-02-15 05:09:17
2019	439	1	2006-02-15 05:09:17
2020	439	1	2006-02-15 05:09:17
2021	439	2	2006-02-15 05:09:17
2022	439	2	2006-02-15 05:09:17
2023	440	1	2006-02-15 05:09:17
2024	440	1	2006-02-15 05:09:17
2025	440	2	2006-02-15 05:09:17
2026	440	2	2006-02-15 05:09:17
2027	441	1	2006-02-15 05:09:17
2028	441	1	2006-02-15 05:09:17
2029	442	1	2006-02-15 05:09:17
2030	442	1	2006-02-15 05:09:17
2031	442	1	2006-02-15 05:09:17
2032	443	1	2006-02-15 05:09:17
2033	443	1	2006-02-15 05:09:17
2034	443	1	2006-02-15 05:09:17
2035	443	2	2006-02-15 05:09:17
2036	443	2	2006-02-15 05:09:17
2037	443	2	2006-02-15 05:09:17
2038	443	2	2006-02-15 05:09:17
2039	444	1	2006-02-15 05:09:17
2040	444	1	2006-02-15 05:09:17
2041	444	1	2006-02-15 05:09:17
2042	444	1	2006-02-15 05:09:17
2043	444	2	2006-02-15 05:09:17
2044	444	2	2006-02-15 05:09:17
2045	444	2	2006-02-15 05:09:17
2046	444	2	2006-02-15 05:09:17
2047	445	1	2006-02-15 05:09:17
2048	445	1	2006-02-15 05:09:17
2049	445	1	2006-02-15 05:09:17
2050	445	2	2006-02-15 05:09:17
2051	445	2	2006-02-15 05:09:17
2052	445	2	2006-02-15 05:09:17
2053	446	1	2006-02-15 05:09:17
2054	446	1	2006-02-15 05:09:17
2055	446	2	2006-02-15 05:09:17
2056	446	2	2006-02-15 05:09:17
2057	447	1	2006-02-15 05:09:17
2058	447	1	2006-02-15 05:09:17
2059	447	1	2006-02-15 05:09:17
2060	447	1	2006-02-15 05:09:17
2061	447	2	2006-02-15 05:09:17
2062	447	2	2006-02-15 05:09:17
2063	447	2	2006-02-15 05:09:17
2064	448	1	2006-02-15 05:09:17
2065	448	1	2006-02-15 05:09:17
2066	448	2	2006-02-15 05:09:17
2067	448	2	2006-02-15 05:09:17
2068	448	2	2006-02-15 05:09:17
2069	449	2	2006-02-15 05:09:17
2070	449	2	2006-02-15 05:09:17
2071	449	2	2006-02-15 05:09:17
2072	449	2	2006-02-15 05:09:17
2073	450	1	2006-02-15 05:09:17
2074	450	1	2006-02-15 05:09:17
2075	450	1	2006-02-15 05:09:17
2076	450	2	2006-02-15 05:09:17
2077	450	2	2006-02-15 05:09:17
2078	450	2	2006-02-15 05:09:17
2079	450	2	2006-02-15 05:09:17
2080	451	1	2006-02-15 05:09:17
2081	451	1	2006-02-15 05:09:17
2082	451	2	2006-02-15 05:09:17
2083	451	2	2006-02-15 05:09:17
2084	451	2	2006-02-15 05:09:17
2085	452	2	2006-02-15 05:09:17
2086	452	2	2006-02-15 05:09:17
2087	452	2	2006-02-15 05:09:17
2088	452	2	2006-02-15 05:09:17
2089	453	1	2006-02-15 05:09:17
2090	453	1	2006-02-15 05:09:17
2091	453	1	2006-02-15 05:09:17
2092	453	2	2006-02-15 05:09:17
2093	453	2	2006-02-15 05:09:17
2094	454	1	2006-02-15 05:09:17
2095	454	1	2006-02-15 05:09:17
2096	455	1	2006-02-15 05:09:17
2097	455	1	2006-02-15 05:09:17
2098	455	1	2006-02-15 05:09:17
2099	455	1	2006-02-15 05:09:17
2100	456	1	2006-02-15 05:09:17
2101	456	1	2006-02-15 05:09:17
2102	456	2	2006-02-15 05:09:17
2103	456	2	2006-02-15 05:09:17
2104	456	2	2006-02-15 05:09:17
2105	456	2	2006-02-15 05:09:17
2106	457	1	2006-02-15 05:09:17
2107	457	1	2006-02-15 05:09:17
2108	457	2	2006-02-15 05:09:17
2109	457	2	2006-02-15 05:09:17
2110	457	2	2006-02-15 05:09:17
2111	457	2	2006-02-15 05:09:17
2112	458	1	2006-02-15 05:09:17
2113	458	1	2006-02-15 05:09:17
2114	458	2	2006-02-15 05:09:17
2115	458	2	2006-02-15 05:09:17
2116	458	2	2006-02-15 05:09:17
2117	458	2	2006-02-15 05:09:17
2118	459	2	2006-02-15 05:09:17
2119	459	2	2006-02-15 05:09:17
2120	460	1	2006-02-15 05:09:17
2121	460	1	2006-02-15 05:09:17
2122	460	1	2006-02-15 05:09:17
2123	460	1	2006-02-15 05:09:17
2124	460	2	2006-02-15 05:09:17
2125	460	2	2006-02-15 05:09:17
2126	460	2	2006-02-15 05:09:17
2127	460	2	2006-02-15 05:09:17
2128	461	1	2006-02-15 05:09:17
2129	461	1	2006-02-15 05:09:17
2130	461	2	2006-02-15 05:09:17
2131	461	2	2006-02-15 05:09:17
2132	461	2	2006-02-15 05:09:17
2133	461	2	2006-02-15 05:09:17
2134	462	1	2006-02-15 05:09:17
2135	462	1	2006-02-15 05:09:17
2136	462	2	2006-02-15 05:09:17
2137	462	2	2006-02-15 05:09:17
2138	462	2	2006-02-15 05:09:17
2139	463	1	2006-02-15 05:09:17
2140	463	1	2006-02-15 05:09:17
2141	463	1	2006-02-15 05:09:17
2142	463	2	2006-02-15 05:09:17
2143	463	2	2006-02-15 05:09:17
2144	464	1	2006-02-15 05:09:17
2145	464	1	2006-02-15 05:09:17
2146	464	1	2006-02-15 05:09:17
2147	464	1	2006-02-15 05:09:17
2148	464	2	2006-02-15 05:09:17
2149	464	2	2006-02-15 05:09:17
2150	464	2	2006-02-15 05:09:17
2151	465	1	2006-02-15 05:09:17
2152	465	1	2006-02-15 05:09:17
2153	465	2	2006-02-15 05:09:17
2154	465	2	2006-02-15 05:09:17
2155	465	2	2006-02-15 05:09:17
2156	466	1	2006-02-15 05:09:17
2157	466	1	2006-02-15 05:09:17
2158	467	1	2006-02-15 05:09:17
2159	467	1	2006-02-15 05:09:17
2160	467	1	2006-02-15 05:09:17
2161	467	1	2006-02-15 05:09:17
2162	467	2	2006-02-15 05:09:17
2163	467	2	2006-02-15 05:09:17
2164	467	2	2006-02-15 05:09:17
2165	468	1	2006-02-15 05:09:17
2166	468	1	2006-02-15 05:09:17
2167	468	1	2006-02-15 05:09:17
2168	468	1	2006-02-15 05:09:17
2169	468	2	2006-02-15 05:09:17
2170	468	2	2006-02-15 05:09:17
2171	468	2	2006-02-15 05:09:17
2172	468	2	2006-02-15 05:09:17
2173	469	2	2006-02-15 05:09:17
2174	469	2	2006-02-15 05:09:17
2175	469	2	2006-02-15 05:09:17
2176	470	1	2006-02-15 05:09:17
2177	470	1	2006-02-15 05:09:17
2178	471	1	2006-02-15 05:09:17
2179	471	1	2006-02-15 05:09:17
2180	471	1	2006-02-15 05:09:17
2181	471	2	2006-02-15 05:09:17
2182	471	2	2006-02-15 05:09:17
2183	471	2	2006-02-15 05:09:17
2184	471	2	2006-02-15 05:09:17
2185	472	2	2006-02-15 05:09:17
2186	472	2	2006-02-15 05:09:17
2187	473	1	2006-02-15 05:09:17
2188	473	1	2006-02-15 05:09:17
2189	473	2	2006-02-15 05:09:17
2190	473	2	2006-02-15 05:09:17
2191	473	2	2006-02-15 05:09:17
2192	474	2	2006-02-15 05:09:17
2193	474	2	2006-02-15 05:09:17
2194	474	2	2006-02-15 05:09:17
2195	474	2	2006-02-15 05:09:17
2196	475	2	2006-02-15 05:09:17
2197	475	2	2006-02-15 05:09:17
2198	476	1	2006-02-15 05:09:17
2199	476	1	2006-02-15 05:09:17
2200	476	1	2006-02-15 05:09:17
2201	476	2	2006-02-15 05:09:17
2202	476	2	2006-02-15 05:09:17
2203	476	2	2006-02-15 05:09:17
2204	476	2	2006-02-15 05:09:17
2205	477	2	2006-02-15 05:09:17
2206	477	2	2006-02-15 05:09:17
2207	477	2	2006-02-15 05:09:17
2208	478	1	2006-02-15 05:09:17
2209	478	1	2006-02-15 05:09:17
2210	478	2	2006-02-15 05:09:17
2211	478	2	2006-02-15 05:09:17
2212	478	2	2006-02-15 05:09:17
2213	479	1	2006-02-15 05:09:17
2214	479	1	2006-02-15 05:09:17
2215	479	2	2006-02-15 05:09:17
2216	479	2	2006-02-15 05:09:17
2217	479	2	2006-02-15 05:09:17
2218	480	1	2006-02-15 05:09:17
2219	480	1	2006-02-15 05:09:17
2220	480	2	2006-02-15 05:09:17
2221	480	2	2006-02-15 05:09:17
2222	481	1	2006-02-15 05:09:17
2223	481	1	2006-02-15 05:09:17
2224	481	1	2006-02-15 05:09:17
2225	481	2	2006-02-15 05:09:17
2226	481	2	2006-02-15 05:09:17
2227	481	2	2006-02-15 05:09:17
2228	482	1	2006-02-15 05:09:17
2229	482	1	2006-02-15 05:09:17
2230	482	1	2006-02-15 05:09:17
2231	483	1	2006-02-15 05:09:17
2232	483	1	2006-02-15 05:09:17
2233	483	1	2006-02-15 05:09:17
2234	483	2	2006-02-15 05:09:17
2235	483	2	2006-02-15 05:09:17
2236	484	1	2006-02-15 05:09:17
2237	484	1	2006-02-15 05:09:17
2238	484	1	2006-02-15 05:09:17
2239	484	1	2006-02-15 05:09:17
2240	484	2	2006-02-15 05:09:17
2241	484	2	2006-02-15 05:09:17
2242	484	2	2006-02-15 05:09:17
2243	485	2	2006-02-15 05:09:17
2244	485	2	2006-02-15 05:09:17
2245	485	2	2006-02-15 05:09:17
2246	486	1	2006-02-15 05:09:17
2247	486	1	2006-02-15 05:09:17
2248	486	1	2006-02-15 05:09:17
2249	486	1	2006-02-15 05:09:17
2250	486	2	2006-02-15 05:09:17
2251	486	2	2006-02-15 05:09:17
2252	487	2	2006-02-15 05:09:17
2253	487	2	2006-02-15 05:09:17
2254	487	2	2006-02-15 05:09:17
2255	488	1	2006-02-15 05:09:17
2256	488	1	2006-02-15 05:09:17
2257	488	2	2006-02-15 05:09:17
2258	488	2	2006-02-15 05:09:17
2259	488	2	2006-02-15 05:09:17
2260	489	1	2006-02-15 05:09:17
2261	489	1	2006-02-15 05:09:17
2262	489	1	2006-02-15 05:09:17
2263	489	1	2006-02-15 05:09:17
2264	489	2	2006-02-15 05:09:17
2265	489	2	2006-02-15 05:09:17
2266	489	2	2006-02-15 05:09:17
2267	489	2	2006-02-15 05:09:17
2268	490	1	2006-02-15 05:09:17
2269	490	1	2006-02-15 05:09:17
2270	491	1	2006-02-15 05:09:17
2271	491	1	2006-02-15 05:09:17
2272	491	2	2006-02-15 05:09:17
2273	491	2	2006-02-15 05:09:17
2274	491	2	2006-02-15 05:09:17
2275	491	2	2006-02-15 05:09:17
2276	492	1	2006-02-15 05:09:17
2277	492	1	2006-02-15 05:09:17
2278	493	2	2006-02-15 05:09:17
2279	493	2	2006-02-15 05:09:17
2280	493	2	2006-02-15 05:09:17
2281	494	1	2006-02-15 05:09:17
2282	494	1	2006-02-15 05:09:17
2283	494	1	2006-02-15 05:09:17
2284	494	1	2006-02-15 05:09:17
2285	494	2	2006-02-15 05:09:17
2286	494	2	2006-02-15 05:09:17
2287	496	1	2006-02-15 05:09:17
2288	496	1	2006-02-15 05:09:17
2289	496	2	2006-02-15 05:09:17
2290	496	2	2006-02-15 05:09:17
2291	496	2	2006-02-15 05:09:17
2292	498	1	2006-02-15 05:09:17
2293	498	1	2006-02-15 05:09:17
2294	499	1	2006-02-15 05:09:17
2295	499	1	2006-02-15 05:09:17
2296	500	1	2006-02-15 05:09:17
2297	500	1	2006-02-15 05:09:17
2298	500	1	2006-02-15 05:09:17
2299	500	1	2006-02-15 05:09:17
2300	500	2	2006-02-15 05:09:17
2301	500	2	2006-02-15 05:09:17
2302	500	2	2006-02-15 05:09:17
2303	500	2	2006-02-15 05:09:17
2304	501	1	2006-02-15 05:09:17
2305	501	1	2006-02-15 05:09:17
2306	501	1	2006-02-15 05:09:17
2307	501	2	2006-02-15 05:09:17
2308	501	2	2006-02-15 05:09:17
2309	502	1	2006-02-15 05:09:17
2310	502	1	2006-02-15 05:09:17
2311	502	1	2006-02-15 05:09:17
2312	502	1	2006-02-15 05:09:17
2313	502	2	2006-02-15 05:09:17
2314	502	2	2006-02-15 05:09:17
2315	502	2	2006-02-15 05:09:17
2316	503	1	2006-02-15 05:09:17
2317	503	1	2006-02-15 05:09:17
2318	503	1	2006-02-15 05:09:17
2319	504	1	2006-02-15 05:09:17
2320	504	1	2006-02-15 05:09:17
2321	504	1	2006-02-15 05:09:17
2322	504	1	2006-02-15 05:09:17
2323	504	2	2006-02-15 05:09:17
2324	504	2	2006-02-15 05:09:17
2325	505	2	2006-02-15 05:09:17
2326	505	2	2006-02-15 05:09:17
2327	505	2	2006-02-15 05:09:17
2328	505	2	2006-02-15 05:09:17
2329	506	1	2006-02-15 05:09:17
2330	506	1	2006-02-15 05:09:17
2331	506	1	2006-02-15 05:09:17
2332	506	1	2006-02-15 05:09:17
2333	506	2	2006-02-15 05:09:17
2334	506	2	2006-02-15 05:09:17
2335	507	2	2006-02-15 05:09:17
2336	507	2	2006-02-15 05:09:17
2337	508	2	2006-02-15 05:09:17
2338	508	2	2006-02-15 05:09:17
2339	508	2	2006-02-15 05:09:17
2340	509	2	2006-02-15 05:09:17
2341	509	2	2006-02-15 05:09:17
2342	509	2	2006-02-15 05:09:17
2343	510	1	2006-02-15 05:09:17
2344	510	1	2006-02-15 05:09:17
2345	510	1	2006-02-15 05:09:17
2346	510	1	2006-02-15 05:09:17
2347	511	1	2006-02-15 05:09:17
2348	511	1	2006-02-15 05:09:17
2349	511	2	2006-02-15 05:09:17
2350	511	2	2006-02-15 05:09:17
2351	511	2	2006-02-15 05:09:17
2352	512	1	2006-02-15 05:09:17
2353	512	1	2006-02-15 05:09:17
2354	512	2	2006-02-15 05:09:17
2355	512	2	2006-02-15 05:09:17
2356	512	2	2006-02-15 05:09:17
2357	512	2	2006-02-15 05:09:17
2358	513	2	2006-02-15 05:09:17
2359	513	2	2006-02-15 05:09:17
2360	514	1	2006-02-15 05:09:17
2361	514	1	2006-02-15 05:09:17
2362	514	2	2006-02-15 05:09:17
2363	514	2	2006-02-15 05:09:17
2364	514	2	2006-02-15 05:09:17
2365	514	2	2006-02-15 05:09:17
2366	515	2	2006-02-15 05:09:17
2367	515	2	2006-02-15 05:09:17
2368	516	2	2006-02-15 05:09:17
2369	516	2	2006-02-15 05:09:17
2370	516	2	2006-02-15 05:09:17
2371	517	2	2006-02-15 05:09:17
2372	517	2	2006-02-15 05:09:17
2373	518	1	2006-02-15 05:09:17
2374	518	1	2006-02-15 05:09:17
2375	518	2	2006-02-15 05:09:17
2376	518	2	2006-02-15 05:09:17
2377	518	2	2006-02-15 05:09:17
2378	518	2	2006-02-15 05:09:17
2379	519	2	2006-02-15 05:09:17
2380	519	2	2006-02-15 05:09:17
2381	519	2	2006-02-15 05:09:17
2382	519	2	2006-02-15 05:09:17
2383	520	1	2006-02-15 05:09:17
2384	520	1	2006-02-15 05:09:17
2385	521	1	2006-02-15 05:09:17
2386	521	1	2006-02-15 05:09:17
2387	521	1	2006-02-15 05:09:17
2388	521	1	2006-02-15 05:09:17
2389	521	2	2006-02-15 05:09:17
2390	521	2	2006-02-15 05:09:17
2391	521	2	2006-02-15 05:09:17
2392	522	2	2006-02-15 05:09:17
2393	522	2	2006-02-15 05:09:17
2394	523	1	2006-02-15 05:09:17
2395	523	1	2006-02-15 05:09:17
2396	524	1	2006-02-15 05:09:17
2397	524	1	2006-02-15 05:09:17
2398	524	2	2006-02-15 05:09:17
2399	524	2	2006-02-15 05:09:17
2400	524	2	2006-02-15 05:09:17
2401	524	2	2006-02-15 05:09:17
2402	525	1	2006-02-15 05:09:17
2403	525	1	2006-02-15 05:09:17
2404	525	1	2006-02-15 05:09:17
2405	525	1	2006-02-15 05:09:17
2406	525	2	2006-02-15 05:09:17
2407	525	2	2006-02-15 05:09:17
2408	525	2	2006-02-15 05:09:17
2409	525	2	2006-02-15 05:09:17
2410	526	2	2006-02-15 05:09:17
2411	526	2	2006-02-15 05:09:17
2412	526	2	2006-02-15 05:09:17
2413	526	2	2006-02-15 05:09:17
2414	527	1	2006-02-15 05:09:17
2415	527	1	2006-02-15 05:09:17
2416	527	2	2006-02-15 05:09:17
2417	527	2	2006-02-15 05:09:17
2418	527	2	2006-02-15 05:09:17
2419	527	2	2006-02-15 05:09:17
2420	528	1	2006-02-15 05:09:17
2421	528	1	2006-02-15 05:09:17
2422	528	1	2006-02-15 05:09:17
2423	529	1	2006-02-15 05:09:17
2424	529	1	2006-02-15 05:09:17
2425	529	1	2006-02-15 05:09:17
2426	529	1	2006-02-15 05:09:17
2427	530	1	2006-02-15 05:09:17
2428	530	1	2006-02-15 05:09:17
2429	530	1	2006-02-15 05:09:17
2430	531	1	2006-02-15 05:09:17
2431	531	1	2006-02-15 05:09:17
2432	531	1	2006-02-15 05:09:17
2433	531	1	2006-02-15 05:09:17
2434	531	2	2006-02-15 05:09:17
2435	531	2	2006-02-15 05:09:17
2436	531	2	2006-02-15 05:09:17
2437	531	2	2006-02-15 05:09:17
2438	532	2	2006-02-15 05:09:17
2439	532	2	2006-02-15 05:09:17
2440	532	2	2006-02-15 05:09:17
2441	532	2	2006-02-15 05:09:17
2442	533	1	2006-02-15 05:09:17
2443	533	1	2006-02-15 05:09:17
2444	533	1	2006-02-15 05:09:17
2445	534	1	2006-02-15 05:09:17
2446	534	1	2006-02-15 05:09:17
2447	534	2	2006-02-15 05:09:17
2448	534	2	2006-02-15 05:09:17
2449	534	2	2006-02-15 05:09:17
2450	535	1	2006-02-15 05:09:17
2451	535	1	2006-02-15 05:09:17
2452	535	1	2006-02-15 05:09:17
2453	535	1	2006-02-15 05:09:17
2454	536	1	2006-02-15 05:09:17
2455	536	1	2006-02-15 05:09:17
2456	536	1	2006-02-15 05:09:17
2457	536	2	2006-02-15 05:09:17
2458	536	2	2006-02-15 05:09:17
2459	537	2	2006-02-15 05:09:17
2460	537	2	2006-02-15 05:09:17
2461	537	2	2006-02-15 05:09:17
2462	538	2	2006-02-15 05:09:17
2463	538	2	2006-02-15 05:09:17
2464	538	2	2006-02-15 05:09:17
2465	539	1	2006-02-15 05:09:17
2466	539	1	2006-02-15 05:09:17
2467	540	1	2006-02-15 05:09:17
2468	540	1	2006-02-15 05:09:17
2469	540	1	2006-02-15 05:09:17
2470	541	2	2006-02-15 05:09:17
2471	541	2	2006-02-15 05:09:17
2472	542	1	2006-02-15 05:09:17
2473	542	1	2006-02-15 05:09:17
2474	542	1	2006-02-15 05:09:17
2475	542	1	2006-02-15 05:09:17
2476	542	2	2006-02-15 05:09:17
2477	542	2	2006-02-15 05:09:17
2478	543	1	2006-02-15 05:09:17
2479	543	1	2006-02-15 05:09:17
2480	544	1	2006-02-15 05:09:17
2481	544	1	2006-02-15 05:09:17
2482	544	2	2006-02-15 05:09:17
2483	544	2	2006-02-15 05:09:17
2484	545	1	2006-02-15 05:09:17
2485	545	1	2006-02-15 05:09:17
2486	545	1	2006-02-15 05:09:17
2487	545	1	2006-02-15 05:09:17
2488	545	2	2006-02-15 05:09:17
2489	545	2	2006-02-15 05:09:17
2490	546	2	2006-02-15 05:09:17
2491	546	2	2006-02-15 05:09:17
2492	546	2	2006-02-15 05:09:17
2493	546	2	2006-02-15 05:09:17
2494	547	2	2006-02-15 05:09:17
2495	547	2	2006-02-15 05:09:17
2496	548	1	2006-02-15 05:09:17
2497	548	1	2006-02-15 05:09:17
2498	549	1	2006-02-15 05:09:17
2499	549	1	2006-02-15 05:09:17
2500	549	2	2006-02-15 05:09:17
2501	549	2	2006-02-15 05:09:17
2502	550	1	2006-02-15 05:09:17
2503	550	1	2006-02-15 05:09:17
2504	550	1	2006-02-15 05:09:17
2505	551	1	2006-02-15 05:09:17
2506	551	1	2006-02-15 05:09:17
2507	551	1	2006-02-15 05:09:17
2508	551	2	2006-02-15 05:09:17
2509	551	2	2006-02-15 05:09:17
2510	551	2	2006-02-15 05:09:17
2511	552	2	2006-02-15 05:09:17
2512	552	2	2006-02-15 05:09:17
2513	552	2	2006-02-15 05:09:17
2514	552	2	2006-02-15 05:09:17
2515	553	2	2006-02-15 05:09:17
2516	553	2	2006-02-15 05:09:17
2517	553	2	2006-02-15 05:09:17
2518	554	1	2006-02-15 05:09:17
2519	554	1	2006-02-15 05:09:17
2520	554	1	2006-02-15 05:09:17
2521	554	1	2006-02-15 05:09:17
2522	554	2	2006-02-15 05:09:17
2523	554	2	2006-02-15 05:09:17
2524	554	2	2006-02-15 05:09:17
2525	555	1	2006-02-15 05:09:17
2526	555	1	2006-02-15 05:09:17
2527	555	1	2006-02-15 05:09:17
2528	555	2	2006-02-15 05:09:17
2529	555	2	2006-02-15 05:09:17
2530	555	2	2006-02-15 05:09:17
2531	555	2	2006-02-15 05:09:17
2532	556	1	2006-02-15 05:09:17
2533	556	1	2006-02-15 05:09:17
2534	556	1	2006-02-15 05:09:17
2535	556	2	2006-02-15 05:09:17
2536	556	2	2006-02-15 05:09:17
2537	556	2	2006-02-15 05:09:17
2538	556	2	2006-02-15 05:09:17
2539	557	1	2006-02-15 05:09:17
2540	557	1	2006-02-15 05:09:17
2541	557	2	2006-02-15 05:09:17
2542	557	2	2006-02-15 05:09:17
2543	557	2	2006-02-15 05:09:17
2544	558	2	2006-02-15 05:09:17
2545	558	2	2006-02-15 05:09:17
2546	559	1	2006-02-15 05:09:17
2547	559	1	2006-02-15 05:09:17
2548	559	1	2006-02-15 05:09:17
2549	559	1	2006-02-15 05:09:17
2550	559	2	2006-02-15 05:09:17
2551	559	2	2006-02-15 05:09:17
2552	559	2	2006-02-15 05:09:17
2553	559	2	2006-02-15 05:09:17
2554	560	1	2006-02-15 05:09:17
2555	560	1	2006-02-15 05:09:17
2556	560	1	2006-02-15 05:09:17
2557	560	2	2006-02-15 05:09:17
2558	560	2	2006-02-15 05:09:17
2559	561	1	2006-02-15 05:09:17
2560	561	1	2006-02-15 05:09:17
2561	561	1	2006-02-15 05:09:17
2562	561	1	2006-02-15 05:09:17
2563	562	1	2006-02-15 05:09:17
2564	562	1	2006-02-15 05:09:17
2565	562	1	2006-02-15 05:09:17
2566	562	1	2006-02-15 05:09:17
2567	562	2	2006-02-15 05:09:17
2568	562	2	2006-02-15 05:09:17
2569	563	1	2006-02-15 05:09:17
2570	563	1	2006-02-15 05:09:17
2571	563	1	2006-02-15 05:09:17
2572	563	1	2006-02-15 05:09:17
2573	563	2	2006-02-15 05:09:17
2574	563	2	2006-02-15 05:09:17
2575	563	2	2006-02-15 05:09:17
2576	564	2	2006-02-15 05:09:17
2577	564	2	2006-02-15 05:09:17
2578	564	2	2006-02-15 05:09:17
2579	565	1	2006-02-15 05:09:17
2580	565	1	2006-02-15 05:09:17
2581	566	1	2006-02-15 05:09:17
2582	566	1	2006-02-15 05:09:17
2583	567	1	2006-02-15 05:09:17
2584	567	1	2006-02-15 05:09:17
2585	567	2	2006-02-15 05:09:17
2586	567	2	2006-02-15 05:09:17
2587	568	1	2006-02-15 05:09:17
2588	568	1	2006-02-15 05:09:17
2589	568	2	2006-02-15 05:09:17
2590	568	2	2006-02-15 05:09:17
2591	569	1	2006-02-15 05:09:17
2592	569	1	2006-02-15 05:09:17
2593	570	1	2006-02-15 05:09:17
2594	570	1	2006-02-15 05:09:17
2595	570	2	2006-02-15 05:09:17
2596	570	2	2006-02-15 05:09:17
2597	570	2	2006-02-15 05:09:17
2598	571	1	2006-02-15 05:09:17
2599	571	1	2006-02-15 05:09:17
2600	571	2	2006-02-15 05:09:17
2601	571	2	2006-02-15 05:09:17
2602	571	2	2006-02-15 05:09:17
2603	571	2	2006-02-15 05:09:17
2604	572	1	2006-02-15 05:09:17
2605	572	1	2006-02-15 05:09:17
2606	572	1	2006-02-15 05:09:17
2607	572	1	2006-02-15 05:09:17
2608	572	2	2006-02-15 05:09:17
2609	572	2	2006-02-15 05:09:17
2610	572	2	2006-02-15 05:09:17
2611	572	2	2006-02-15 05:09:17
2612	573	1	2006-02-15 05:09:17
2613	573	1	2006-02-15 05:09:17
2614	573	1	2006-02-15 05:09:17
2615	573	1	2006-02-15 05:09:17
2616	574	1	2006-02-15 05:09:17
2617	574	1	2006-02-15 05:09:17
2618	574	2	2006-02-15 05:09:17
2619	574	2	2006-02-15 05:09:17
2620	574	2	2006-02-15 05:09:17
2621	575	1	2006-02-15 05:09:17
2622	575	1	2006-02-15 05:09:17
2623	575	2	2006-02-15 05:09:17
2624	575	2	2006-02-15 05:09:17
2625	575	2	2006-02-15 05:09:17
2626	575	2	2006-02-15 05:09:17
2627	576	2	2006-02-15 05:09:17
2628	576	2	2006-02-15 05:09:17
2629	576	2	2006-02-15 05:09:17
2630	577	1	2006-02-15 05:09:17
2631	577	1	2006-02-15 05:09:17
2632	577	1	2006-02-15 05:09:17
2633	578	1	2006-02-15 05:09:17
2634	578	1	2006-02-15 05:09:17
2635	578	2	2006-02-15 05:09:17
2636	578	2	2006-02-15 05:09:17
2637	578	2	2006-02-15 05:09:17
2638	579	1	2006-02-15 05:09:17
2639	579	1	2006-02-15 05:09:17
2640	579	1	2006-02-15 05:09:17
2641	579	1	2006-02-15 05:09:17
2642	579	2	2006-02-15 05:09:17
2643	579	2	2006-02-15 05:09:17
2644	579	2	2006-02-15 05:09:17
2645	580	1	2006-02-15 05:09:17
2646	580	1	2006-02-15 05:09:17
2647	580	1	2006-02-15 05:09:17
2648	580	1	2006-02-15 05:09:17
2649	580	2	2006-02-15 05:09:17
2650	580	2	2006-02-15 05:09:17
2651	581	1	2006-02-15 05:09:17
2652	581	1	2006-02-15 05:09:17
2653	581	1	2006-02-15 05:09:17
2654	582	2	2006-02-15 05:09:17
2655	582	2	2006-02-15 05:09:17
2656	583	1	2006-02-15 05:09:17
2657	583	1	2006-02-15 05:09:17
2658	583	1	2006-02-15 05:09:17
2659	583	2	2006-02-15 05:09:17
2660	583	2	2006-02-15 05:09:17
2661	584	1	2006-02-15 05:09:17
2662	584	1	2006-02-15 05:09:17
2663	585	2	2006-02-15 05:09:17
2664	585	2	2006-02-15 05:09:17
2665	585	2	2006-02-15 05:09:17
2666	585	2	2006-02-15 05:09:17
2667	586	1	2006-02-15 05:09:17
2668	586	1	2006-02-15 05:09:17
2669	586	1	2006-02-15 05:09:17
2670	586	1	2006-02-15 05:09:17
2671	586	2	2006-02-15 05:09:17
2672	586	2	2006-02-15 05:09:17
2673	586	2	2006-02-15 05:09:17
2674	586	2	2006-02-15 05:09:17
2675	587	1	2006-02-15 05:09:17
2676	587	1	2006-02-15 05:09:17
2677	587	1	2006-02-15 05:09:17
2678	588	2	2006-02-15 05:09:17
2679	588	2	2006-02-15 05:09:17
2680	588	2	2006-02-15 05:09:17
2681	588	2	2006-02-15 05:09:17
2682	589	2	2006-02-15 05:09:17
2683	589	2	2006-02-15 05:09:17
2684	589	2	2006-02-15 05:09:17
2685	589	2	2006-02-15 05:09:17
2686	590	1	2006-02-15 05:09:17
2687	590	1	2006-02-15 05:09:17
2688	590	1	2006-02-15 05:09:17
2689	590	2	2006-02-15 05:09:17
2690	590	2	2006-02-15 05:09:17
2691	590	2	2006-02-15 05:09:17
2692	590	2	2006-02-15 05:09:17
2693	591	2	2006-02-15 05:09:17
2694	591	2	2006-02-15 05:09:17
2695	591	2	2006-02-15 05:09:17
2696	592	1	2006-02-15 05:09:17
2697	592	1	2006-02-15 05:09:17
2698	592	2	2006-02-15 05:09:17
2699	592	2	2006-02-15 05:09:17
2700	593	2	2006-02-15 05:09:17
2701	593	2	2006-02-15 05:09:17
2702	593	2	2006-02-15 05:09:17
2703	593	2	2006-02-15 05:09:17
2704	594	1	2006-02-15 05:09:17
2705	594	1	2006-02-15 05:09:17
2706	594	1	2006-02-15 05:09:17
2707	595	1	2006-02-15 05:09:17
2708	595	1	2006-02-15 05:09:17
2709	595	1	2006-02-15 05:09:17
2710	595	1	2006-02-15 05:09:17
2711	595	2	2006-02-15 05:09:17
2712	595	2	2006-02-15 05:09:17
2713	595	2	2006-02-15 05:09:17
2714	595	2	2006-02-15 05:09:17
2715	596	1	2006-02-15 05:09:17
2716	596	1	2006-02-15 05:09:17
2717	596	2	2006-02-15 05:09:17
2718	596	2	2006-02-15 05:09:17
2719	596	2	2006-02-15 05:09:17
2720	596	2	2006-02-15 05:09:17
2721	597	2	2006-02-15 05:09:17
2722	597	2	2006-02-15 05:09:17
2723	597	2	2006-02-15 05:09:17
2724	597	2	2006-02-15 05:09:17
2725	598	1	2006-02-15 05:09:17
2726	598	1	2006-02-15 05:09:17
2727	598	1	2006-02-15 05:09:17
2728	598	1	2006-02-15 05:09:17
2729	599	1	2006-02-15 05:09:17
2730	599	1	2006-02-15 05:09:17
2731	599	1	2006-02-15 05:09:17
2732	599	2	2006-02-15 05:09:17
2733	599	2	2006-02-15 05:09:17
2734	600	1	2006-02-15 05:09:17
2735	600	1	2006-02-15 05:09:17
2736	600	2	2006-02-15 05:09:17
2737	600	2	2006-02-15 05:09:17
2738	601	1	2006-02-15 05:09:17
2739	601	1	2006-02-15 05:09:17
2740	601	1	2006-02-15 05:09:17
2741	601	2	2006-02-15 05:09:17
2742	601	2	2006-02-15 05:09:17
2743	602	1	2006-02-15 05:09:17
2744	602	1	2006-02-15 05:09:17
2745	602	2	2006-02-15 05:09:17
2746	602	2	2006-02-15 05:09:17
2747	602	2	2006-02-15 05:09:17
2748	603	1	2006-02-15 05:09:17
2749	603	1	2006-02-15 05:09:17
2750	603	1	2006-02-15 05:09:17
2751	603	1	2006-02-15 05:09:17
2752	603	2	2006-02-15 05:09:17
2753	603	2	2006-02-15 05:09:17
2754	604	2	2006-02-15 05:09:17
2755	604	2	2006-02-15 05:09:17
2756	604	2	2006-02-15 05:09:17
2757	605	2	2006-02-15 05:09:17
2758	605	2	2006-02-15 05:09:17
2759	606	1	2006-02-15 05:09:17
2760	606	1	2006-02-15 05:09:17
2761	606	2	2006-02-15 05:09:17
2762	606	2	2006-02-15 05:09:17
2763	606	2	2006-02-15 05:09:17
2764	606	2	2006-02-15 05:09:17
2765	608	1	2006-02-15 05:09:17
2766	608	1	2006-02-15 05:09:17
2767	608	2	2006-02-15 05:09:17
2768	608	2	2006-02-15 05:09:17
2769	608	2	2006-02-15 05:09:17
2770	608	2	2006-02-15 05:09:17
2771	609	1	2006-02-15 05:09:17
2772	609	1	2006-02-15 05:09:17
2773	609	1	2006-02-15 05:09:17
2774	609	1	2006-02-15 05:09:17
2775	609	2	2006-02-15 05:09:17
2776	609	2	2006-02-15 05:09:17
2777	609	2	2006-02-15 05:09:17
2778	609	2	2006-02-15 05:09:17
2779	610	1	2006-02-15 05:09:17
2780	610	1	2006-02-15 05:09:17
2781	610	2	2006-02-15 05:09:17
2782	610	2	2006-02-15 05:09:17
2783	610	2	2006-02-15 05:09:17
2784	611	1	2006-02-15 05:09:17
2785	611	1	2006-02-15 05:09:17
2786	611	1	2006-02-15 05:09:17
2787	611	1	2006-02-15 05:09:17
2788	611	2	2006-02-15 05:09:17
2789	611	2	2006-02-15 05:09:17
2790	612	2	2006-02-15 05:09:17
2791	612	2	2006-02-15 05:09:17
2792	613	1	2006-02-15 05:09:17
2793	613	1	2006-02-15 05:09:17
2794	614	1	2006-02-15 05:09:17
2795	614	1	2006-02-15 05:09:17
2796	614	1	2006-02-15 05:09:17
2797	614	2	2006-02-15 05:09:17
2798	614	2	2006-02-15 05:09:17
2799	614	2	2006-02-15 05:09:17
2800	615	2	2006-02-15 05:09:17
2801	615	2	2006-02-15 05:09:17
2802	615	2	2006-02-15 05:09:17
2803	615	2	2006-02-15 05:09:17
2804	616	1	2006-02-15 05:09:17
2805	616	1	2006-02-15 05:09:17
2806	616	2	2006-02-15 05:09:17
2807	616	2	2006-02-15 05:09:17
2808	616	2	2006-02-15 05:09:17
2809	616	2	2006-02-15 05:09:17
2810	617	1	2006-02-15 05:09:17
2811	617	1	2006-02-15 05:09:17
2812	617	1	2006-02-15 05:09:17
2813	618	2	2006-02-15 05:09:17
2814	618	2	2006-02-15 05:09:17
2815	618	2	2006-02-15 05:09:17
2816	618	2	2006-02-15 05:09:17
2817	619	1	2006-02-15 05:09:17
2818	619	1	2006-02-15 05:09:17
2819	619	2	2006-02-15 05:09:17
2820	619	2	2006-02-15 05:09:17
2821	619	2	2006-02-15 05:09:17
2822	619	2	2006-02-15 05:09:17
2823	620	1	2006-02-15 05:09:17
2824	620	1	2006-02-15 05:09:17
2825	620	2	2006-02-15 05:09:17
2826	620	2	2006-02-15 05:09:17
2827	620	2	2006-02-15 05:09:17
2828	621	1	2006-02-15 05:09:17
2829	621	1	2006-02-15 05:09:17
2830	621	1	2006-02-15 05:09:17
2831	621	1	2006-02-15 05:09:17
2832	621	2	2006-02-15 05:09:17
2833	621	2	2006-02-15 05:09:17
2834	621	2	2006-02-15 05:09:17
2835	621	2	2006-02-15 05:09:17
2836	622	2	2006-02-15 05:09:17
2837	622	2	2006-02-15 05:09:17
2838	623	1	2006-02-15 05:09:17
2839	623	1	2006-02-15 05:09:17
2840	623	2	2006-02-15 05:09:17
2841	623	2	2006-02-15 05:09:17
2842	623	2	2006-02-15 05:09:17
2843	624	1	2006-02-15 05:09:17
2844	624	1	2006-02-15 05:09:17
2845	624	1	2006-02-15 05:09:17
2846	624	2	2006-02-15 05:09:17
2847	624	2	2006-02-15 05:09:17
2848	624	2	2006-02-15 05:09:17
2849	624	2	2006-02-15 05:09:17
2850	625	1	2006-02-15 05:09:17
2851	625	1	2006-02-15 05:09:17
2852	625	1	2006-02-15 05:09:17
2853	625	2	2006-02-15 05:09:17
2854	625	2	2006-02-15 05:09:17
2855	625	2	2006-02-15 05:09:17
2856	625	2	2006-02-15 05:09:17
2857	626	2	2006-02-15 05:09:17
2858	626	2	2006-02-15 05:09:17
2859	626	2	2006-02-15 05:09:17
2860	626	2	2006-02-15 05:09:17
2861	627	2	2006-02-15 05:09:17
2862	627	2	2006-02-15 05:09:17
2863	627	2	2006-02-15 05:09:17
2864	628	1	2006-02-15 05:09:17
2865	628	1	2006-02-15 05:09:17
2866	628	1	2006-02-15 05:09:17
2867	628	2	2006-02-15 05:09:17
2868	628	2	2006-02-15 05:09:17
2869	629	2	2006-02-15 05:09:17
2870	629	2	2006-02-15 05:09:17
2871	629	2	2006-02-15 05:09:17
2872	629	2	2006-02-15 05:09:17
2873	630	2	2006-02-15 05:09:17
2874	630	2	2006-02-15 05:09:17
2875	630	2	2006-02-15 05:09:17
2876	631	1	2006-02-15 05:09:17
2877	631	1	2006-02-15 05:09:17
2878	631	1	2006-02-15 05:09:17
2879	631	2	2006-02-15 05:09:17
2880	631	2	2006-02-15 05:09:17
2881	632	1	2006-02-15 05:09:17
2882	632	1	2006-02-15 05:09:17
2883	632	1	2006-02-15 05:09:17
2884	633	2	2006-02-15 05:09:17
2885	633	2	2006-02-15 05:09:17
2886	633	2	2006-02-15 05:09:17
2887	634	2	2006-02-15 05:09:17
2888	634	2	2006-02-15 05:09:17
2889	634	2	2006-02-15 05:09:17
2890	634	2	2006-02-15 05:09:17
2891	635	2	2006-02-15 05:09:17
2892	635	2	2006-02-15 05:09:17
2893	636	1	2006-02-15 05:09:17
2894	636	1	2006-02-15 05:09:17
2895	636	1	2006-02-15 05:09:17
2896	637	1	2006-02-15 05:09:17
2897	637	1	2006-02-15 05:09:17
2898	637	2	2006-02-15 05:09:17
2899	637	2	2006-02-15 05:09:17
2900	637	2	2006-02-15 05:09:17
2901	638	1	2006-02-15 05:09:17
2902	638	1	2006-02-15 05:09:17
2903	638	1	2006-02-15 05:09:17
2904	638	1	2006-02-15 05:09:17
2905	638	2	2006-02-15 05:09:17
2906	638	2	2006-02-15 05:09:17
2907	638	2	2006-02-15 05:09:17
2908	638	2	2006-02-15 05:09:17
2909	639	2	2006-02-15 05:09:17
2910	639	2	2006-02-15 05:09:17
2911	639	2	2006-02-15 05:09:17
2912	640	2	2006-02-15 05:09:17
2913	640	2	2006-02-15 05:09:17
2914	640	2	2006-02-15 05:09:17
2915	641	1	2006-02-15 05:09:17
2916	641	1	2006-02-15 05:09:17
2917	641	1	2006-02-15 05:09:17
2918	641	2	2006-02-15 05:09:17
2919	641	2	2006-02-15 05:09:17
2920	641	2	2006-02-15 05:09:17
2921	641	2	2006-02-15 05:09:17
2922	643	1	2006-02-15 05:09:17
2923	643	1	2006-02-15 05:09:17
2924	643	1	2006-02-15 05:09:17
2925	643	2	2006-02-15 05:09:17
2926	643	2	2006-02-15 05:09:17
2927	643	2	2006-02-15 05:09:17
2928	644	1	2006-02-15 05:09:17
2929	644	1	2006-02-15 05:09:17
2930	644	1	2006-02-15 05:09:17
2931	644	2	2006-02-15 05:09:17
2932	644	2	2006-02-15 05:09:17
2933	644	2	2006-02-15 05:09:17
2934	644	2	2006-02-15 05:09:17
2935	645	1	2006-02-15 05:09:17
2936	645	1	2006-02-15 05:09:17
2937	645	1	2006-02-15 05:09:17
2938	645	2	2006-02-15 05:09:17
2939	645	2	2006-02-15 05:09:17
2940	645	2	2006-02-15 05:09:17
2941	646	1	2006-02-15 05:09:17
2942	646	1	2006-02-15 05:09:17
2943	646	1	2006-02-15 05:09:17
2944	646	2	2006-02-15 05:09:17
2945	646	2	2006-02-15 05:09:17
2946	647	1	2006-02-15 05:09:17
2947	647	1	2006-02-15 05:09:17
2948	647	1	2006-02-15 05:09:17
2949	647	2	2006-02-15 05:09:17
2950	647	2	2006-02-15 05:09:17
2951	647	2	2006-02-15 05:09:17
2952	648	1	2006-02-15 05:09:17
2953	648	1	2006-02-15 05:09:17
2954	648	1	2006-02-15 05:09:17
2955	648	1	2006-02-15 05:09:17
2956	648	2	2006-02-15 05:09:17
2957	648	2	2006-02-15 05:09:17
2958	649	1	2006-02-15 05:09:17
2959	649	1	2006-02-15 05:09:17
2960	649	2	2006-02-15 05:09:17
2961	649	2	2006-02-15 05:09:17
2962	649	2	2006-02-15 05:09:17
2963	649	2	2006-02-15 05:09:17
2964	650	1	2006-02-15 05:09:17
2965	650	1	2006-02-15 05:09:17
2966	650	2	2006-02-15 05:09:17
2967	650	2	2006-02-15 05:09:17
2968	650	2	2006-02-15 05:09:17
2969	650	2	2006-02-15 05:09:17
2970	651	1	2006-02-15 05:09:17
2971	651	1	2006-02-15 05:09:17
2972	651	2	2006-02-15 05:09:17
2973	651	2	2006-02-15 05:09:17
2974	651	2	2006-02-15 05:09:17
2975	651	2	2006-02-15 05:09:17
2976	652	1	2006-02-15 05:09:17
2977	652	1	2006-02-15 05:09:17
2978	652	1	2006-02-15 05:09:17
2979	652	1	2006-02-15 05:09:17
2980	653	1	2006-02-15 05:09:17
2981	653	1	2006-02-15 05:09:17
2982	654	1	2006-02-15 05:09:17
2983	654	1	2006-02-15 05:09:17
2984	654	2	2006-02-15 05:09:17
2985	654	2	2006-02-15 05:09:17
2986	655	1	2006-02-15 05:09:17
2987	655	1	2006-02-15 05:09:17
2988	655	1	2006-02-15 05:09:17
2989	655	2	2006-02-15 05:09:17
2990	655	2	2006-02-15 05:09:17
2991	655	2	2006-02-15 05:09:17
2992	656	2	2006-02-15 05:09:17
2993	656	2	2006-02-15 05:09:17
2994	657	1	2006-02-15 05:09:17
2995	657	1	2006-02-15 05:09:17
2996	657	1	2006-02-15 05:09:17
2997	657	1	2006-02-15 05:09:17
2998	657	2	2006-02-15 05:09:17
2999	657	2	2006-02-15 05:09:17
3000	658	2	2006-02-15 05:09:17
3001	658	2	2006-02-15 05:09:17
3002	658	2	2006-02-15 05:09:17
3003	658	2	2006-02-15 05:09:17
3004	659	2	2006-02-15 05:09:17
3005	659	2	2006-02-15 05:09:17
3006	660	1	2006-02-15 05:09:17
3007	660	1	2006-02-15 05:09:17
3008	660	2	2006-02-15 05:09:17
3009	660	2	2006-02-15 05:09:17
3010	661	1	2006-02-15 05:09:17
3011	661	1	2006-02-15 05:09:17
3012	661	1	2006-02-15 05:09:17
3013	661	1	2006-02-15 05:09:17
3014	662	1	2006-02-15 05:09:17
3015	662	1	2006-02-15 05:09:17
3016	662	2	2006-02-15 05:09:17
3017	662	2	2006-02-15 05:09:17
3018	663	1	2006-02-15 05:09:17
3019	663	1	2006-02-15 05:09:17
3020	663	1	2006-02-15 05:09:17
3021	663	2	2006-02-15 05:09:17
3022	663	2	2006-02-15 05:09:17
3023	664	1	2006-02-15 05:09:17
3024	664	1	2006-02-15 05:09:17
3025	664	2	2006-02-15 05:09:17
3026	664	2	2006-02-15 05:09:17
3027	664	2	2006-02-15 05:09:17
3028	665	1	2006-02-15 05:09:17
3029	665	1	2006-02-15 05:09:17
3030	665	1	2006-02-15 05:09:17
3031	665	1	2006-02-15 05:09:17
3032	665	2	2006-02-15 05:09:17
3033	665	2	2006-02-15 05:09:17
3034	665	2	2006-02-15 05:09:17
3035	666	1	2006-02-15 05:09:17
3036	666	1	2006-02-15 05:09:17
3037	666	1	2006-02-15 05:09:17
3038	666	2	2006-02-15 05:09:17
3039	666	2	2006-02-15 05:09:17
3040	667	1	2006-02-15 05:09:17
3041	667	1	2006-02-15 05:09:17
3042	667	2	2006-02-15 05:09:17
3043	667	2	2006-02-15 05:09:17
3044	668	1	2006-02-15 05:09:17
3045	668	1	2006-02-15 05:09:17
3046	668	2	2006-02-15 05:09:17
3047	668	2	2006-02-15 05:09:17
3048	668	2	2006-02-15 05:09:17
3049	670	1	2006-02-15 05:09:17
3050	670	1	2006-02-15 05:09:17
3051	670	1	2006-02-15 05:09:17
3052	670	1	2006-02-15 05:09:17
3053	670	2	2006-02-15 05:09:17
3054	670	2	2006-02-15 05:09:17
3055	670	2	2006-02-15 05:09:17
3056	672	1	2006-02-15 05:09:17
3057	672	1	2006-02-15 05:09:17
3058	672	2	2006-02-15 05:09:17
3059	672	2	2006-02-15 05:09:17
3060	672	2	2006-02-15 05:09:17
3061	672	2	2006-02-15 05:09:17
3062	673	1	2006-02-15 05:09:17
3063	673	1	2006-02-15 05:09:17
3064	673	2	2006-02-15 05:09:17
3065	673	2	2006-02-15 05:09:17
3066	674	1	2006-02-15 05:09:17
3067	674	1	2006-02-15 05:09:17
3068	674	1	2006-02-15 05:09:17
3069	675	1	2006-02-15 05:09:17
3070	675	1	2006-02-15 05:09:17
3071	676	1	2006-02-15 05:09:17
3072	676	1	2006-02-15 05:09:17
3073	676	2	2006-02-15 05:09:17
3074	676	2	2006-02-15 05:09:17
3075	676	2	2006-02-15 05:09:17
3076	676	2	2006-02-15 05:09:17
3077	677	1	2006-02-15 05:09:17
3078	677	1	2006-02-15 05:09:17
3079	677	1	2006-02-15 05:09:17
3080	677	2	2006-02-15 05:09:17
3081	677	2	2006-02-15 05:09:17
3082	677	2	2006-02-15 05:09:17
3083	677	2	2006-02-15 05:09:17
3084	678	1	2006-02-15 05:09:17
3085	678	1	2006-02-15 05:09:17
3086	678	1	2006-02-15 05:09:17
3087	678	1	2006-02-15 05:09:17
3088	679	1	2006-02-15 05:09:17
3089	679	1	2006-02-15 05:09:17
3090	679	2	2006-02-15 05:09:17
3091	679	2	2006-02-15 05:09:17
3092	680	1	2006-02-15 05:09:17
3093	680	1	2006-02-15 05:09:17
3094	680	2	2006-02-15 05:09:17
3095	680	2	2006-02-15 05:09:17
3096	680	2	2006-02-15 05:09:17
3097	680	2	2006-02-15 05:09:17
3098	681	1	2006-02-15 05:09:17
3099	681	1	2006-02-15 05:09:17
3100	681	1	2006-02-15 05:09:17
3101	681	2	2006-02-15 05:09:17
3102	681	2	2006-02-15 05:09:17
3103	681	2	2006-02-15 05:09:17
3104	682	1	2006-02-15 05:09:17
3105	682	1	2006-02-15 05:09:17
3106	682	1	2006-02-15 05:09:17
3107	683	1	2006-02-15 05:09:17
3108	683	1	2006-02-15 05:09:17
3109	683	1	2006-02-15 05:09:17
3110	683	1	2006-02-15 05:09:17
3111	683	2	2006-02-15 05:09:17
3112	683	2	2006-02-15 05:09:17
3113	683	2	2006-02-15 05:09:17
3114	683	2	2006-02-15 05:09:17
3115	684	2	2006-02-15 05:09:17
3116	684	2	2006-02-15 05:09:17
3117	685	2	2006-02-15 05:09:17
3118	685	2	2006-02-15 05:09:17
3119	686	1	2006-02-15 05:09:17
3120	686	1	2006-02-15 05:09:17
3121	686	1	2006-02-15 05:09:17
3122	686	1	2006-02-15 05:09:17
3123	687	1	2006-02-15 05:09:17
3124	687	1	2006-02-15 05:09:17
3125	687	1	2006-02-15 05:09:17
3126	687	2	2006-02-15 05:09:17
3127	687	2	2006-02-15 05:09:17
3128	687	2	2006-02-15 05:09:17
3129	687	2	2006-02-15 05:09:17
3130	688	2	2006-02-15 05:09:17
3131	688	2	2006-02-15 05:09:17
3132	688	2	2006-02-15 05:09:17
3133	688	2	2006-02-15 05:09:17
3134	689	1	2006-02-15 05:09:17
3135	689	1	2006-02-15 05:09:17
3136	689	1	2006-02-15 05:09:17
3137	689	1	2006-02-15 05:09:17
3138	689	2	2006-02-15 05:09:17
3139	689	2	2006-02-15 05:09:17
3140	690	1	2006-02-15 05:09:17
3141	690	1	2006-02-15 05:09:17
3142	690	1	2006-02-15 05:09:17
3143	690	1	2006-02-15 05:09:17
3144	690	2	2006-02-15 05:09:17
3145	690	2	2006-02-15 05:09:17
3146	691	1	2006-02-15 05:09:17
3147	691	1	2006-02-15 05:09:17
3148	691	1	2006-02-15 05:09:17
3149	691	2	2006-02-15 05:09:17
3150	691	2	2006-02-15 05:09:17
3151	692	2	2006-02-15 05:09:17
3152	692	2	2006-02-15 05:09:17
3153	692	2	2006-02-15 05:09:17
3154	693	1	2006-02-15 05:09:17
3155	693	1	2006-02-15 05:09:17
3156	693	2	2006-02-15 05:09:17
3157	693	2	2006-02-15 05:09:17
3158	693	2	2006-02-15 05:09:17
3159	694	1	2006-02-15 05:09:17
3160	694	1	2006-02-15 05:09:17
3161	694	1	2006-02-15 05:09:17
3162	694	1	2006-02-15 05:09:17
3163	694	2	2006-02-15 05:09:17
3164	694	2	2006-02-15 05:09:17
3165	695	1	2006-02-15 05:09:17
3166	695	1	2006-02-15 05:09:17
3167	696	1	2006-02-15 05:09:17
3168	696	1	2006-02-15 05:09:17
3169	696	2	2006-02-15 05:09:17
3170	696	2	2006-02-15 05:09:17
3171	696	2	2006-02-15 05:09:17
3172	697	1	2006-02-15 05:09:17
3173	697	1	2006-02-15 05:09:17
3174	697	1	2006-02-15 05:09:17
3175	697	1	2006-02-15 05:09:17
3176	697	2	2006-02-15 05:09:17
3177	697	2	2006-02-15 05:09:17
3178	697	2	2006-02-15 05:09:17
3179	697	2	2006-02-15 05:09:17
3180	698	1	2006-02-15 05:09:17
3181	698	1	2006-02-15 05:09:17
3182	698	1	2006-02-15 05:09:17
3183	698	1	2006-02-15 05:09:17
3184	698	2	2006-02-15 05:09:17
3185	698	2	2006-02-15 05:09:17
3186	698	2	2006-02-15 05:09:17
3187	699	1	2006-02-15 05:09:17
3188	699	1	2006-02-15 05:09:17
3189	700	2	2006-02-15 05:09:17
3190	700	2	2006-02-15 05:09:17
3191	700	2	2006-02-15 05:09:17
3192	702	1	2006-02-15 05:09:17
3193	702	1	2006-02-15 05:09:17
3194	702	1	2006-02-15 05:09:17
3195	702	1	2006-02-15 05:09:17
3196	702	2	2006-02-15 05:09:17
3197	702	2	2006-02-15 05:09:17
3198	702	2	2006-02-15 05:09:17
3199	702	2	2006-02-15 05:09:17
3200	703	2	2006-02-15 05:09:17
3201	703	2	2006-02-15 05:09:17
3202	704	1	2006-02-15 05:09:17
3203	704	1	2006-02-15 05:09:17
3204	704	2	2006-02-15 05:09:17
3205	704	2	2006-02-15 05:09:17
3206	704	2	2006-02-15 05:09:17
3207	705	1	2006-02-15 05:09:17
3208	705	1	2006-02-15 05:09:17
3209	705	1	2006-02-15 05:09:17
3210	705	1	2006-02-15 05:09:17
3211	706	1	2006-02-15 05:09:17
3212	706	1	2006-02-15 05:09:17
3213	706	2	2006-02-15 05:09:17
3214	706	2	2006-02-15 05:09:17
3215	706	2	2006-02-15 05:09:17
3216	706	2	2006-02-15 05:09:17
3217	707	1	2006-02-15 05:09:17
3218	707	1	2006-02-15 05:09:17
3219	707	2	2006-02-15 05:09:17
3220	707	2	2006-02-15 05:09:17
3221	707	2	2006-02-15 05:09:17
3222	707	2	2006-02-15 05:09:17
3223	708	1	2006-02-15 05:09:17
3224	708	1	2006-02-15 05:09:17
3225	708	2	2006-02-15 05:09:17
3226	708	2	2006-02-15 05:09:17
3227	709	1	2006-02-15 05:09:17
3228	709	1	2006-02-15 05:09:17
3229	709	2	2006-02-15 05:09:17
3230	709	2	2006-02-15 05:09:17
3231	709	2	2006-02-15 05:09:17
3232	709	2	2006-02-15 05:09:17
3233	710	1	2006-02-15 05:09:17
3234	710	1	2006-02-15 05:09:17
3235	710	1	2006-02-15 05:09:17
3236	710	1	2006-02-15 05:09:17
3237	710	2	2006-02-15 05:09:17
3238	710	2	2006-02-15 05:09:17
3239	711	2	2006-02-15 05:09:17
3240	711	2	2006-02-15 05:09:17
3241	711	2	2006-02-15 05:09:17
3242	711	2	2006-02-15 05:09:17
3243	714	2	2006-02-15 05:09:17
3244	714	2	2006-02-15 05:09:17
3245	714	2	2006-02-15 05:09:17
3246	715	1	2006-02-15 05:09:17
3247	715	1	2006-02-15 05:09:17
3248	715	1	2006-02-15 05:09:17
3249	715	1	2006-02-15 05:09:17
3250	715	2	2006-02-15 05:09:17
3251	715	2	2006-02-15 05:09:17
3252	715	2	2006-02-15 05:09:17
3253	716	1	2006-02-15 05:09:17
3254	716	1	2006-02-15 05:09:17
3255	716	2	2006-02-15 05:09:17
3256	716	2	2006-02-15 05:09:17
3257	716	2	2006-02-15 05:09:17
3258	717	1	2006-02-15 05:09:17
3259	717	1	2006-02-15 05:09:17
3260	717	2	2006-02-15 05:09:17
3261	717	2	2006-02-15 05:09:17
3262	718	2	2006-02-15 05:09:17
3263	718	2	2006-02-15 05:09:17
3264	719	1	2006-02-15 05:09:17
3265	719	1	2006-02-15 05:09:17
3266	720	1	2006-02-15 05:09:17
3267	720	1	2006-02-15 05:09:17
3268	720	1	2006-02-15 05:09:17
3269	720	2	2006-02-15 05:09:17
3270	720	2	2006-02-15 05:09:17
3271	720	2	2006-02-15 05:09:17
3272	720	2	2006-02-15 05:09:17
3273	721	1	2006-02-15 05:09:17
3274	721	1	2006-02-15 05:09:17
3275	722	1	2006-02-15 05:09:17
3276	722	1	2006-02-15 05:09:17
3277	722	2	2006-02-15 05:09:17
3278	722	2	2006-02-15 05:09:17
3279	723	1	2006-02-15 05:09:17
3280	723	1	2006-02-15 05:09:17
3281	723	1	2006-02-15 05:09:17
3282	723	1	2006-02-15 05:09:17
3283	723	2	2006-02-15 05:09:17
3284	723	2	2006-02-15 05:09:17
3285	723	2	2006-02-15 05:09:17
3286	724	1	2006-02-15 05:09:17
3287	724	1	2006-02-15 05:09:17
3288	724	2	2006-02-15 05:09:17
3289	724	2	2006-02-15 05:09:17
3290	724	2	2006-02-15 05:09:17
3291	724	2	2006-02-15 05:09:17
3292	725	1	2006-02-15 05:09:17
3293	725	1	2006-02-15 05:09:17
3294	725	1	2006-02-15 05:09:17
3295	725	2	2006-02-15 05:09:17
3296	725	2	2006-02-15 05:09:17
3297	725	2	2006-02-15 05:09:17
3298	726	2	2006-02-15 05:09:17
3299	726	2	2006-02-15 05:09:17
3300	726	2	2006-02-15 05:09:17
3301	727	1	2006-02-15 05:09:17
3302	727	1	2006-02-15 05:09:17
3303	727	2	2006-02-15 05:09:17
3304	727	2	2006-02-15 05:09:17
3305	727	2	2006-02-15 05:09:17
3306	728	1	2006-02-15 05:09:17
3307	728	1	2006-02-15 05:09:17
3308	728	1	2006-02-15 05:09:17
3309	728	2	2006-02-15 05:09:17
3310	728	2	2006-02-15 05:09:17
3311	729	2	2006-02-15 05:09:17
3312	729	2	2006-02-15 05:09:17
3313	729	2	2006-02-15 05:09:17
3314	729	2	2006-02-15 05:09:17
3315	730	1	2006-02-15 05:09:17
3316	730	1	2006-02-15 05:09:17
3317	730	1	2006-02-15 05:09:17
3318	730	1	2006-02-15 05:09:17
3319	730	2	2006-02-15 05:09:17
3320	730	2	2006-02-15 05:09:17
3321	730	2	2006-02-15 05:09:17
3322	730	2	2006-02-15 05:09:17
3323	731	2	2006-02-15 05:09:17
3324	731	2	2006-02-15 05:09:17
3325	731	2	2006-02-15 05:09:17
3326	732	1	2006-02-15 05:09:17
3327	732	1	2006-02-15 05:09:17
3328	732	1	2006-02-15 05:09:17
3329	732	1	2006-02-15 05:09:17
3330	733	1	2006-02-15 05:09:17
3331	733	1	2006-02-15 05:09:17
3332	733	1	2006-02-15 05:09:17
3333	733	1	2006-02-15 05:09:17
3334	733	2	2006-02-15 05:09:17
3335	733	2	2006-02-15 05:09:17
3336	733	2	2006-02-15 05:09:17
3337	734	1	2006-02-15 05:09:17
3338	734	1	2006-02-15 05:09:17
3339	734	2	2006-02-15 05:09:17
3340	734	2	2006-02-15 05:09:17
3341	734	2	2006-02-15 05:09:17
3342	734	2	2006-02-15 05:09:17
3343	735	1	2006-02-15 05:09:17
3344	735	1	2006-02-15 05:09:17
3345	735	1	2006-02-15 05:09:17
3346	735	2	2006-02-15 05:09:17
3347	735	2	2006-02-15 05:09:17
3348	735	2	2006-02-15 05:09:17
3349	735	2	2006-02-15 05:09:17
3350	736	1	2006-02-15 05:09:17
3351	736	1	2006-02-15 05:09:17
3352	736	1	2006-02-15 05:09:17
3353	736	1	2006-02-15 05:09:17
3354	737	1	2006-02-15 05:09:17
3355	737	1	2006-02-15 05:09:17
3356	737	2	2006-02-15 05:09:17
3357	737	2	2006-02-15 05:09:17
3358	737	2	2006-02-15 05:09:17
3359	737	2	2006-02-15 05:09:17
3360	738	1	2006-02-15 05:09:17
3361	738	1	2006-02-15 05:09:17
3362	738	1	2006-02-15 05:09:17
3363	738	1	2006-02-15 05:09:17
3364	738	2	2006-02-15 05:09:17
3365	738	2	2006-02-15 05:09:17
3366	738	2	2006-02-15 05:09:17
3367	738	2	2006-02-15 05:09:17
3368	739	1	2006-02-15 05:09:17
3369	739	1	2006-02-15 05:09:17
3370	739	2	2006-02-15 05:09:17
3371	739	2	2006-02-15 05:09:17
3372	739	2	2006-02-15 05:09:17
3373	740	2	2006-02-15 05:09:17
3374	740	2	2006-02-15 05:09:17
3375	740	2	2006-02-15 05:09:17
3376	741	1	2006-02-15 05:09:17
3377	741	1	2006-02-15 05:09:17
3378	741	1	2006-02-15 05:09:17
3379	741	1	2006-02-15 05:09:17
3380	741	2	2006-02-15 05:09:17
3381	741	2	2006-02-15 05:09:17
3382	743	1	2006-02-15 05:09:17
3383	743	1	2006-02-15 05:09:17
3384	743	2	2006-02-15 05:09:17
3385	743	2	2006-02-15 05:09:17
3386	743	2	2006-02-15 05:09:17
3387	743	2	2006-02-15 05:09:17
3388	744	1	2006-02-15 05:09:17
3389	744	1	2006-02-15 05:09:17
3390	744	2	2006-02-15 05:09:17
3391	744	2	2006-02-15 05:09:17
3392	744	2	2006-02-15 05:09:17
3393	745	1	2006-02-15 05:09:17
3394	745	1	2006-02-15 05:09:17
3395	745	1	2006-02-15 05:09:17
3396	745	1	2006-02-15 05:09:17
3397	745	2	2006-02-15 05:09:17
3398	745	2	2006-02-15 05:09:17
3399	745	2	2006-02-15 05:09:17
3400	745	2	2006-02-15 05:09:17
3401	746	1	2006-02-15 05:09:17
3402	746	1	2006-02-15 05:09:17
3403	746	2	2006-02-15 05:09:17
3404	746	2	2006-02-15 05:09:17
3405	746	2	2006-02-15 05:09:17
3406	747	1	2006-02-15 05:09:17
3407	747	1	2006-02-15 05:09:17
3408	747	2	2006-02-15 05:09:17
3409	747	2	2006-02-15 05:09:17
3410	747	2	2006-02-15 05:09:17
3411	748	1	2006-02-15 05:09:17
3412	748	1	2006-02-15 05:09:17
3413	748	1	2006-02-15 05:09:17
3414	748	1	2006-02-15 05:09:17
3415	748	2	2006-02-15 05:09:17
3416	748	2	2006-02-15 05:09:17
3417	748	2	2006-02-15 05:09:17
3418	748	2	2006-02-15 05:09:17
3419	749	1	2006-02-15 05:09:17
3420	749	1	2006-02-15 05:09:17
3421	749	2	2006-02-15 05:09:17
3422	749	2	2006-02-15 05:09:17
3423	750	1	2006-02-15 05:09:17
3424	750	1	2006-02-15 05:09:17
3425	750	1	2006-02-15 05:09:17
3426	751	2	2006-02-15 05:09:17
3427	751	2	2006-02-15 05:09:17
3428	752	2	2006-02-15 05:09:17
3429	752	2	2006-02-15 05:09:17
3430	752	2	2006-02-15 05:09:17
3431	753	1	2006-02-15 05:09:17
3432	753	1	2006-02-15 05:09:17
3433	753	1	2006-02-15 05:09:17
3434	753	1	2006-02-15 05:09:17
3435	753	2	2006-02-15 05:09:17
3436	753	2	2006-02-15 05:09:17
3437	753	2	2006-02-15 05:09:17
3438	753	2	2006-02-15 05:09:17
3439	754	2	2006-02-15 05:09:17
3440	754	2	2006-02-15 05:09:17
3441	755	1	2006-02-15 05:09:17
3442	755	1	2006-02-15 05:09:17
3443	755	1	2006-02-15 05:09:17
3444	755	1	2006-02-15 05:09:17
3445	755	2	2006-02-15 05:09:17
3446	755	2	2006-02-15 05:09:17
3447	755	2	2006-02-15 05:09:17
3448	756	2	2006-02-15 05:09:17
3449	756	2	2006-02-15 05:09:17
3450	756	2	2006-02-15 05:09:17
3451	757	1	2006-02-15 05:09:17
3452	757	1	2006-02-15 05:09:17
3453	757	1	2006-02-15 05:09:17
3454	757	2	2006-02-15 05:09:17
3455	757	2	2006-02-15 05:09:17
3456	758	2	2006-02-15 05:09:17
3457	758	2	2006-02-15 05:09:17
3458	758	2	2006-02-15 05:09:17
3459	759	1	2006-02-15 05:09:17
3460	759	1	2006-02-15 05:09:17
3461	759	2	2006-02-15 05:09:17
3462	759	2	2006-02-15 05:09:17
3463	759	2	2006-02-15 05:09:17
3464	759	2	2006-02-15 05:09:17
3465	760	1	2006-02-15 05:09:17
3466	760	1	2006-02-15 05:09:17
3467	760	1	2006-02-15 05:09:17
3468	760	2	2006-02-15 05:09:17
3469	760	2	2006-02-15 05:09:17
3470	760	2	2006-02-15 05:09:17
3471	760	2	2006-02-15 05:09:17
3472	761	2	2006-02-15 05:09:17
3473	761	2	2006-02-15 05:09:17
3474	761	2	2006-02-15 05:09:17
3475	762	2	2006-02-15 05:09:17
3476	762	2	2006-02-15 05:09:17
3477	762	2	2006-02-15 05:09:17
3478	762	2	2006-02-15 05:09:17
3479	763	1	2006-02-15 05:09:17
3480	763	1	2006-02-15 05:09:17
3481	763	1	2006-02-15 05:09:17
3482	763	2	2006-02-15 05:09:17
3483	763	2	2006-02-15 05:09:17
3484	764	1	2006-02-15 05:09:17
3485	764	1	2006-02-15 05:09:17
3486	764	1	2006-02-15 05:09:17
3487	764	1	2006-02-15 05:09:17
3488	764	2	2006-02-15 05:09:17
3489	764	2	2006-02-15 05:09:17
3490	764	2	2006-02-15 05:09:17
3491	764	2	2006-02-15 05:09:17
3492	765	1	2006-02-15 05:09:17
3493	765	1	2006-02-15 05:09:17
3494	765	1	2006-02-15 05:09:17
3495	765	1	2006-02-15 05:09:17
3496	766	1	2006-02-15 05:09:17
3497	766	1	2006-02-15 05:09:17
3498	766	1	2006-02-15 05:09:17
3499	767	1	2006-02-15 05:09:17
3500	767	1	2006-02-15 05:09:17
3501	767	1	2006-02-15 05:09:17
3502	767	1	2006-02-15 05:09:17
3503	767	2	2006-02-15 05:09:17
3504	767	2	2006-02-15 05:09:17
3505	767	2	2006-02-15 05:09:17
3506	767	2	2006-02-15 05:09:17
3507	768	1	2006-02-15 05:09:17
3508	768	1	2006-02-15 05:09:17
3509	768	1	2006-02-15 05:09:17
3510	768	2	2006-02-15 05:09:17
3511	768	2	2006-02-15 05:09:17
3512	768	2	2006-02-15 05:09:17
3513	769	2	2006-02-15 05:09:17
3514	769	2	2006-02-15 05:09:17
3515	770	2	2006-02-15 05:09:17
3516	770	2	2006-02-15 05:09:17
3517	770	2	2006-02-15 05:09:17
3518	771	1	2006-02-15 05:09:17
3519	771	1	2006-02-15 05:09:17
3520	771	1	2006-02-15 05:09:17
3521	771	2	2006-02-15 05:09:17
3522	771	2	2006-02-15 05:09:17
3523	771	2	2006-02-15 05:09:17
3524	771	2	2006-02-15 05:09:17
3525	772	1	2006-02-15 05:09:17
3526	772	1	2006-02-15 05:09:17
3527	772	1	2006-02-15 05:09:17
3528	772	1	2006-02-15 05:09:17
3529	772	2	2006-02-15 05:09:17
3530	772	2	2006-02-15 05:09:17
3531	773	1	2006-02-15 05:09:17
3532	773	1	2006-02-15 05:09:17
3533	773	1	2006-02-15 05:09:17
3534	773	1	2006-02-15 05:09:17
3535	773	2	2006-02-15 05:09:17
3536	773	2	2006-02-15 05:09:17
3537	773	2	2006-02-15 05:09:17
3538	773	2	2006-02-15 05:09:17
3539	774	1	2006-02-15 05:09:17
3540	774	1	2006-02-15 05:09:17
3541	774	1	2006-02-15 05:09:17
3542	774	1	2006-02-15 05:09:17
3543	775	1	2006-02-15 05:09:17
3544	775	1	2006-02-15 05:09:17
3545	775	1	2006-02-15 05:09:17
3546	775	2	2006-02-15 05:09:17
3547	775	2	2006-02-15 05:09:17
3548	776	1	2006-02-15 05:09:17
3549	776	1	2006-02-15 05:09:17
3550	776	2	2006-02-15 05:09:17
3551	776	2	2006-02-15 05:09:17
3552	776	2	2006-02-15 05:09:17
3553	777	1	2006-02-15 05:09:17
3554	777	1	2006-02-15 05:09:17
3555	777	1	2006-02-15 05:09:17
3556	777	2	2006-02-15 05:09:17
3557	777	2	2006-02-15 05:09:17
3558	777	2	2006-02-15 05:09:17
3559	778	1	2006-02-15 05:09:17
3560	778	1	2006-02-15 05:09:17
3561	778	1	2006-02-15 05:09:17
3562	778	1	2006-02-15 05:09:17
3563	778	2	2006-02-15 05:09:17
3564	778	2	2006-02-15 05:09:17
3565	779	2	2006-02-15 05:09:17
3566	779	2	2006-02-15 05:09:17
3567	780	2	2006-02-15 05:09:17
3568	780	2	2006-02-15 05:09:17
3569	780	2	2006-02-15 05:09:17
3570	781	2	2006-02-15 05:09:17
3571	781	2	2006-02-15 05:09:17
3572	782	1	2006-02-15 05:09:17
3573	782	1	2006-02-15 05:09:17
3574	782	1	2006-02-15 05:09:17
3575	782	2	2006-02-15 05:09:17
3576	782	2	2006-02-15 05:09:17
3577	782	2	2006-02-15 05:09:17
3578	783	1	2006-02-15 05:09:17
3579	783	1	2006-02-15 05:09:17
3580	783	1	2006-02-15 05:09:17
3581	783	1	2006-02-15 05:09:17
3582	784	1	2006-02-15 05:09:17
3583	784	1	2006-02-15 05:09:17
3584	784	1	2006-02-15 05:09:17
3585	784	2	2006-02-15 05:09:17
3586	784	2	2006-02-15 05:09:17
3587	784	2	2006-02-15 05:09:17
3588	785	1	2006-02-15 05:09:17
3589	785	1	2006-02-15 05:09:17
3590	785	1	2006-02-15 05:09:17
3591	785	1	2006-02-15 05:09:17
3592	785	2	2006-02-15 05:09:17
3593	785	2	2006-02-15 05:09:17
3594	786	1	2006-02-15 05:09:17
3595	786	1	2006-02-15 05:09:17
3596	786	1	2006-02-15 05:09:17
3597	786	2	2006-02-15 05:09:17
3598	786	2	2006-02-15 05:09:17
3599	786	2	2006-02-15 05:09:17
3600	786	2	2006-02-15 05:09:17
3601	787	1	2006-02-15 05:09:17
3602	787	1	2006-02-15 05:09:17
3603	787	1	2006-02-15 05:09:17
3604	788	1	2006-02-15 05:09:17
3605	788	1	2006-02-15 05:09:17
3606	788	2	2006-02-15 05:09:17
3607	788	2	2006-02-15 05:09:17
3608	789	1	2006-02-15 05:09:17
3609	789	1	2006-02-15 05:09:17
3610	789	1	2006-02-15 05:09:17
3611	789	1	2006-02-15 05:09:17
3612	789	2	2006-02-15 05:09:17
3613	789	2	2006-02-15 05:09:17
3614	789	2	2006-02-15 05:09:17
3615	789	2	2006-02-15 05:09:17
3616	790	1	2006-02-15 05:09:17
3617	790	1	2006-02-15 05:09:17
3618	790	1	2006-02-15 05:09:17
3619	790	1	2006-02-15 05:09:17
3620	790	2	2006-02-15 05:09:17
3621	790	2	2006-02-15 05:09:17
3622	790	2	2006-02-15 05:09:17
3623	791	1	2006-02-15 05:09:17
3624	791	1	2006-02-15 05:09:17
3625	791	2	2006-02-15 05:09:17
3626	791	2	2006-02-15 05:09:17
3627	791	2	2006-02-15 05:09:17
3628	791	2	2006-02-15 05:09:17
3629	792	2	2006-02-15 05:09:17
3630	792	2	2006-02-15 05:09:17
3631	792	2	2006-02-15 05:09:17
3632	793	1	2006-02-15 05:09:17
3633	793	1	2006-02-15 05:09:17
3634	793	1	2006-02-15 05:09:17
3635	793	1	2006-02-15 05:09:17
3636	794	1	2006-02-15 05:09:17
3637	794	1	2006-02-15 05:09:17
3638	794	2	2006-02-15 05:09:17
3639	794	2	2006-02-15 05:09:17
3640	795	1	2006-02-15 05:09:17
3641	795	1	2006-02-15 05:09:17
3642	795	1	2006-02-15 05:09:17
3643	795	1	2006-02-15 05:09:17
3644	796	1	2006-02-15 05:09:17
3645	796	1	2006-02-15 05:09:17
3646	796	2	2006-02-15 05:09:17
3647	796	2	2006-02-15 05:09:17
3648	796	2	2006-02-15 05:09:17
3649	797	1	2006-02-15 05:09:17
3650	797	1	2006-02-15 05:09:17
3651	797	2	2006-02-15 05:09:17
3652	797	2	2006-02-15 05:09:17
3653	797	2	2006-02-15 05:09:17
3654	798	1	2006-02-15 05:09:17
3655	798	1	2006-02-15 05:09:17
3656	798	2	2006-02-15 05:09:17
3657	798	2	2006-02-15 05:09:17
3658	799	1	2006-02-15 05:09:17
3659	799	1	2006-02-15 05:09:17
3660	800	1	2006-02-15 05:09:17
3661	800	1	2006-02-15 05:09:17
3662	800	2	2006-02-15 05:09:17
3663	800	2	2006-02-15 05:09:17
3664	800	2	2006-02-15 05:09:17
3665	800	2	2006-02-15 05:09:17
3666	803	1	2006-02-15 05:09:17
3667	803	1	2006-02-15 05:09:17
3668	803	1	2006-02-15 05:09:17
3669	803	1	2006-02-15 05:09:17
3670	803	2	2006-02-15 05:09:17
3671	803	2	2006-02-15 05:09:17
3672	804	1	2006-02-15 05:09:17
3673	804	1	2006-02-15 05:09:17
3674	804	1	2006-02-15 05:09:17
3675	804	1	2006-02-15 05:09:17
3676	804	2	2006-02-15 05:09:17
3677	804	2	2006-02-15 05:09:17
3678	804	2	2006-02-15 05:09:17
3679	805	1	2006-02-15 05:09:17
3680	805	1	2006-02-15 05:09:17
3681	805	2	2006-02-15 05:09:17
3682	805	2	2006-02-15 05:09:17
3683	805	2	2006-02-15 05:09:17
3684	806	1	2006-02-15 05:09:17
3685	806	1	2006-02-15 05:09:17
3686	806	1	2006-02-15 05:09:17
3687	806	2	2006-02-15 05:09:17
3688	806	2	2006-02-15 05:09:17
3689	807	1	2006-02-15 05:09:17
3690	807	1	2006-02-15 05:09:17
3691	807	1	2006-02-15 05:09:17
3692	807	2	2006-02-15 05:09:17
3693	807	2	2006-02-15 05:09:17
3694	808	2	2006-02-15 05:09:17
3695	808	2	2006-02-15 05:09:17
3696	809	2	2006-02-15 05:09:17
3697	809	2	2006-02-15 05:09:17
3698	809	2	2006-02-15 05:09:17
3699	809	2	2006-02-15 05:09:17
3700	810	1	2006-02-15 05:09:17
3701	810	1	2006-02-15 05:09:17
3702	810	1	2006-02-15 05:09:17
3703	810	1	2006-02-15 05:09:17
3704	810	2	2006-02-15 05:09:17
3705	810	2	2006-02-15 05:09:17
3706	810	2	2006-02-15 05:09:17
3707	811	1	2006-02-15 05:09:17
3708	811	1	2006-02-15 05:09:17
3709	811	1	2006-02-15 05:09:17
3710	812	1	2006-02-15 05:09:17
3711	812	1	2006-02-15 05:09:17
3712	812	1	2006-02-15 05:09:17
3713	812	2	2006-02-15 05:09:17
3714	812	2	2006-02-15 05:09:17
3715	812	2	2006-02-15 05:09:17
3716	813	2	2006-02-15 05:09:17
3717	813	2	2006-02-15 05:09:17
3718	813	2	2006-02-15 05:09:17
3719	813	2	2006-02-15 05:09:17
3720	814	1	2006-02-15 05:09:17
3721	814	1	2006-02-15 05:09:17
3722	814	1	2006-02-15 05:09:17
3723	814	2	2006-02-15 05:09:17
3724	814	2	2006-02-15 05:09:17
3725	814	2	2006-02-15 05:09:17
3726	814	2	2006-02-15 05:09:17
3727	815	1	2006-02-15 05:09:17
3728	815	1	2006-02-15 05:09:17
3729	815	1	2006-02-15 05:09:17
3730	816	1	2006-02-15 05:09:17
3731	816	1	2006-02-15 05:09:17
3732	816	1	2006-02-15 05:09:17
3733	816	1	2006-02-15 05:09:17
3734	816	2	2006-02-15 05:09:17
3735	816	2	2006-02-15 05:09:17
3736	816	2	2006-02-15 05:09:17
3737	817	1	2006-02-15 05:09:17
3738	817	1	2006-02-15 05:09:17
3739	818	1	2006-02-15 05:09:17
3740	818	1	2006-02-15 05:09:17
3741	818	1	2006-02-15 05:09:17
3742	818	2	2006-02-15 05:09:17
3743	818	2	2006-02-15 05:09:17
3744	819	1	2006-02-15 05:09:17
3745	819	1	2006-02-15 05:09:17
3746	819	1	2006-02-15 05:09:17
3747	820	1	2006-02-15 05:09:17
3748	820	1	2006-02-15 05:09:17
3749	820	1	2006-02-15 05:09:17
3750	820	1	2006-02-15 05:09:17
3751	820	2	2006-02-15 05:09:17
3752	820	2	2006-02-15 05:09:17
3753	821	2	2006-02-15 05:09:17
3754	821	2	2006-02-15 05:09:17
3755	821	2	2006-02-15 05:09:17
3756	821	2	2006-02-15 05:09:17
3757	822	2	2006-02-15 05:09:17
3758	822	2	2006-02-15 05:09:17
3759	823	1	2006-02-15 05:09:17
3760	823	1	2006-02-15 05:09:17
3761	823	1	2006-02-15 05:09:17
3762	823	2	2006-02-15 05:09:17
3763	823	2	2006-02-15 05:09:17
3764	823	2	2006-02-15 05:09:17
3765	823	2	2006-02-15 05:09:17
3766	824	2	2006-02-15 05:09:17
3767	824	2	2006-02-15 05:09:17
3768	824	2	2006-02-15 05:09:17
3769	824	2	2006-02-15 05:09:17
3770	825	1	2006-02-15 05:09:17
3771	825	1	2006-02-15 05:09:17
3772	825	1	2006-02-15 05:09:17
3773	826	2	2006-02-15 05:09:17
3774	826	2	2006-02-15 05:09:17
3775	827	1	2006-02-15 05:09:17
3776	827	1	2006-02-15 05:09:17
3777	827	2	2006-02-15 05:09:17
3778	827	2	2006-02-15 05:09:17
3779	827	2	2006-02-15 05:09:17
3780	827	2	2006-02-15 05:09:17
3781	828	2	2006-02-15 05:09:17
3782	828	2	2006-02-15 05:09:17
3783	828	2	2006-02-15 05:09:17
3784	828	2	2006-02-15 05:09:17
3785	829	1	2006-02-15 05:09:17
3786	829	1	2006-02-15 05:09:17
3787	829	2	2006-02-15 05:09:17
3788	829	2	2006-02-15 05:09:17
3789	829	2	2006-02-15 05:09:17
3790	830	2	2006-02-15 05:09:17
3791	830	2	2006-02-15 05:09:17
3792	830	2	2006-02-15 05:09:17
3793	830	2	2006-02-15 05:09:17
3794	831	1	2006-02-15 05:09:17
3795	831	1	2006-02-15 05:09:17
3796	831	1	2006-02-15 05:09:17
3797	832	1	2006-02-15 05:09:17
3798	832	1	2006-02-15 05:09:17
3799	832	1	2006-02-15 05:09:17
3800	832	1	2006-02-15 05:09:17
3801	833	1	2006-02-15 05:09:17
3802	833	1	2006-02-15 05:09:17
3803	833	1	2006-02-15 05:09:17
3804	833	2	2006-02-15 05:09:17
3805	833	2	2006-02-15 05:09:17
3806	833	2	2006-02-15 05:09:17
3807	833	2	2006-02-15 05:09:17
3808	834	2	2006-02-15 05:09:17
3809	834	2	2006-02-15 05:09:17
3810	834	2	2006-02-15 05:09:17
3811	835	1	2006-02-15 05:09:17
3812	835	1	2006-02-15 05:09:17
3813	835	1	2006-02-15 05:09:17
3814	835	1	2006-02-15 05:09:17
3815	835	2	2006-02-15 05:09:17
3816	835	2	2006-02-15 05:09:17
3817	835	2	2006-02-15 05:09:17
3818	835	2	2006-02-15 05:09:17
3819	836	1	2006-02-15 05:09:17
3820	836	1	2006-02-15 05:09:17
3821	836	1	2006-02-15 05:09:17
3822	837	2	2006-02-15 05:09:17
3823	837	2	2006-02-15 05:09:17
3824	837	2	2006-02-15 05:09:17
3825	838	1	2006-02-15 05:09:17
3826	838	1	2006-02-15 05:09:17
3827	838	2	2006-02-15 05:09:17
3828	838	2	2006-02-15 05:09:17
3829	838	2	2006-02-15 05:09:17
3830	838	2	2006-02-15 05:09:17
3831	839	2	2006-02-15 05:09:17
3832	839	2	2006-02-15 05:09:17
3833	840	1	2006-02-15 05:09:17
3834	840	1	2006-02-15 05:09:17
3835	840	1	2006-02-15 05:09:17
3836	840	1	2006-02-15 05:09:17
3837	841	1	2006-02-15 05:09:17
3838	841	1	2006-02-15 05:09:17
3839	841	1	2006-02-15 05:09:17
3840	841	2	2006-02-15 05:09:17
3841	841	2	2006-02-15 05:09:17
3842	841	2	2006-02-15 05:09:17
3843	841	2	2006-02-15 05:09:17
3844	842	1	2006-02-15 05:09:17
3845	842	1	2006-02-15 05:09:17
3846	842	2	2006-02-15 05:09:17
3847	842	2	2006-02-15 05:09:17
3848	843	1	2006-02-15 05:09:17
3849	843	1	2006-02-15 05:09:17
3850	843	1	2006-02-15 05:09:17
3851	843	1	2006-02-15 05:09:17
3852	843	2	2006-02-15 05:09:17
3853	843	2	2006-02-15 05:09:17
3854	843	2	2006-02-15 05:09:17
3855	844	1	2006-02-15 05:09:17
3856	844	1	2006-02-15 05:09:17
3857	844	2	2006-02-15 05:09:17
3858	844	2	2006-02-15 05:09:17
3859	845	1	2006-02-15 05:09:17
3860	845	1	2006-02-15 05:09:17
3861	845	1	2006-02-15 05:09:17
3862	845	1	2006-02-15 05:09:17
3863	845	2	2006-02-15 05:09:17
3864	845	2	2006-02-15 05:09:17
3865	845	2	2006-02-15 05:09:17
3866	846	1	2006-02-15 05:09:17
3867	846	1	2006-02-15 05:09:17
3868	846	1	2006-02-15 05:09:17
3869	846	1	2006-02-15 05:09:17
3870	846	2	2006-02-15 05:09:17
3871	846	2	2006-02-15 05:09:17
3872	846	2	2006-02-15 05:09:17
3873	846	2	2006-02-15 05:09:17
3874	847	2	2006-02-15 05:09:17
3875	847	2	2006-02-15 05:09:17
3876	847	2	2006-02-15 05:09:17
3877	847	2	2006-02-15 05:09:17
3878	848	1	2006-02-15 05:09:17
3879	848	1	2006-02-15 05:09:17
3880	848	1	2006-02-15 05:09:17
3881	849	1	2006-02-15 05:09:17
3882	849	1	2006-02-15 05:09:17
3883	849	1	2006-02-15 05:09:17
3884	849	1	2006-02-15 05:09:17
3885	849	2	2006-02-15 05:09:17
3886	849	2	2006-02-15 05:09:17
3887	849	2	2006-02-15 05:09:17
3888	849	2	2006-02-15 05:09:17
3889	850	1	2006-02-15 05:09:17
3890	850	1	2006-02-15 05:09:17
3891	850	1	2006-02-15 05:09:17
3892	850	2	2006-02-15 05:09:17
3893	850	2	2006-02-15 05:09:17
3894	850	2	2006-02-15 05:09:17
3895	850	2	2006-02-15 05:09:17
3896	851	1	2006-02-15 05:09:17
3897	851	1	2006-02-15 05:09:17
3898	851	1	2006-02-15 05:09:17
3899	851	2	2006-02-15 05:09:17
3900	851	2	2006-02-15 05:09:17
3901	851	2	2006-02-15 05:09:17
3902	852	1	2006-02-15 05:09:17
3903	852	1	2006-02-15 05:09:17
3904	852	1	2006-02-15 05:09:17
3905	852	1	2006-02-15 05:09:17
3906	852	2	2006-02-15 05:09:17
3907	852	2	2006-02-15 05:09:17
3908	852	2	2006-02-15 05:09:17
3909	853	1	2006-02-15 05:09:17
3910	853	1	2006-02-15 05:09:17
3911	853	1	2006-02-15 05:09:17
3912	854	2	2006-02-15 05:09:17
3913	854	2	2006-02-15 05:09:17
3914	854	2	2006-02-15 05:09:17
3915	854	2	2006-02-15 05:09:17
3916	855	1	2006-02-15 05:09:17
3917	855	1	2006-02-15 05:09:17
3918	855	2	2006-02-15 05:09:17
3919	855	2	2006-02-15 05:09:17
3920	856	1	2006-02-15 05:09:17
3921	856	1	2006-02-15 05:09:17
3922	856	1	2006-02-15 05:09:17
3923	856	1	2006-02-15 05:09:17
3924	856	2	2006-02-15 05:09:17
3925	856	2	2006-02-15 05:09:17
3926	856	2	2006-02-15 05:09:17
3927	856	2	2006-02-15 05:09:17
3928	857	1	2006-02-15 05:09:17
3929	857	1	2006-02-15 05:09:17
3930	857	1	2006-02-15 05:09:17
3931	857	2	2006-02-15 05:09:17
3932	857	2	2006-02-15 05:09:17
3933	857	2	2006-02-15 05:09:17
3934	857	2	2006-02-15 05:09:17
3935	858	2	2006-02-15 05:09:17
3936	858	2	2006-02-15 05:09:17
3937	858	2	2006-02-15 05:09:17
3938	858	2	2006-02-15 05:09:17
3939	859	1	2006-02-15 05:09:17
3940	859	1	2006-02-15 05:09:17
3941	859	1	2006-02-15 05:09:17
3942	859	2	2006-02-15 05:09:17
3943	859	2	2006-02-15 05:09:17
3944	859	2	2006-02-15 05:09:17
3945	861	1	2006-02-15 05:09:17
3946	861	1	2006-02-15 05:09:17
3947	861	1	2006-02-15 05:09:17
3948	861	2	2006-02-15 05:09:17
3949	861	2	2006-02-15 05:09:17
3950	861	2	2006-02-15 05:09:17
3951	862	1	2006-02-15 05:09:17
3952	862	1	2006-02-15 05:09:17
3953	862	1	2006-02-15 05:09:17
3954	862	2	2006-02-15 05:09:17
3955	862	2	2006-02-15 05:09:17
3956	863	1	2006-02-15 05:09:17
3957	863	1	2006-02-15 05:09:17
3958	863	1	2006-02-15 05:09:17
3959	863	1	2006-02-15 05:09:17
3960	863	2	2006-02-15 05:09:17
3961	863	2	2006-02-15 05:09:17
3962	863	2	2006-02-15 05:09:17
3963	864	1	2006-02-15 05:09:17
3964	864	1	2006-02-15 05:09:17
3965	864	1	2006-02-15 05:09:17
3966	864	1	2006-02-15 05:09:17
3967	864	2	2006-02-15 05:09:17
3968	864	2	2006-02-15 05:09:17
3969	865	1	2006-02-15 05:09:17
3970	865	1	2006-02-15 05:09:17
3971	865	1	2006-02-15 05:09:17
3972	865	1	2006-02-15 05:09:17
3973	865	2	2006-02-15 05:09:17
3974	865	2	2006-02-15 05:09:17
3975	866	2	2006-02-15 05:09:17
3976	866	2	2006-02-15 05:09:17
3977	867	1	2006-02-15 05:09:17
3978	867	1	2006-02-15 05:09:17
3979	867	1	2006-02-15 05:09:17
3980	867	1	2006-02-15 05:09:17
3981	868	1	2006-02-15 05:09:17
3982	868	1	2006-02-15 05:09:17
3983	868	1	2006-02-15 05:09:17
3984	869	1	2006-02-15 05:09:17
3985	869	1	2006-02-15 05:09:17
3986	869	1	2006-02-15 05:09:17
3987	869	1	2006-02-15 05:09:17
3988	869	2	2006-02-15 05:09:17
3989	869	2	2006-02-15 05:09:17
3990	869	2	2006-02-15 05:09:17
3991	870	1	2006-02-15 05:09:17
3992	870	1	2006-02-15 05:09:17
3993	870	1	2006-02-15 05:09:17
3994	870	1	2006-02-15 05:09:17
3995	870	2	2006-02-15 05:09:17
3996	870	2	2006-02-15 05:09:17
3997	870	2	2006-02-15 05:09:17
3998	870	2	2006-02-15 05:09:17
3999	871	1	2006-02-15 05:09:17
4000	871	1	2006-02-15 05:09:17
4001	871	2	2006-02-15 05:09:17
4002	871	2	2006-02-15 05:09:17
4003	871	2	2006-02-15 05:09:17
4004	872	2	2006-02-15 05:09:17
4005	872	2	2006-02-15 05:09:17
4006	872	2	2006-02-15 05:09:17
4007	873	1	2006-02-15 05:09:17
4008	873	1	2006-02-15 05:09:17
4009	873	1	2006-02-15 05:09:17
4010	873	1	2006-02-15 05:09:17
4011	873	2	2006-02-15 05:09:17
4012	873	2	2006-02-15 05:09:17
4013	873	2	2006-02-15 05:09:17
4014	873	2	2006-02-15 05:09:17
4015	875	1	2006-02-15 05:09:17
4016	875	1	2006-02-15 05:09:17
4017	875	1	2006-02-15 05:09:17
4018	875	2	2006-02-15 05:09:17
4019	875	2	2006-02-15 05:09:17
4020	875	2	2006-02-15 05:09:17
4021	875	2	2006-02-15 05:09:17
4022	876	1	2006-02-15 05:09:17
4023	876	1	2006-02-15 05:09:17
4024	877	1	2006-02-15 05:09:17
4025	877	1	2006-02-15 05:09:17
4026	877	1	2006-02-15 05:09:17
4027	877	2	2006-02-15 05:09:17
4028	877	2	2006-02-15 05:09:17
4029	878	2	2006-02-15 05:09:17
4030	878	2	2006-02-15 05:09:17
4031	878	2	2006-02-15 05:09:17
4032	878	2	2006-02-15 05:09:17
4033	879	1	2006-02-15 05:09:17
4034	879	1	2006-02-15 05:09:17
4035	879	1	2006-02-15 05:09:17
4036	879	1	2006-02-15 05:09:17
4037	879	2	2006-02-15 05:09:17
4038	879	2	2006-02-15 05:09:17
4039	879	2	2006-02-15 05:09:17
4040	880	1	2006-02-15 05:09:17
4041	880	1	2006-02-15 05:09:17
4042	880	1	2006-02-15 05:09:17
4043	880	1	2006-02-15 05:09:17
4044	880	2	2006-02-15 05:09:17
4045	880	2	2006-02-15 05:09:17
4046	880	2	2006-02-15 05:09:17
4047	880	2	2006-02-15 05:09:17
4048	881	2	2006-02-15 05:09:17
4049	881	2	2006-02-15 05:09:17
4050	881	2	2006-02-15 05:09:17
4051	881	2	2006-02-15 05:09:17
4052	882	1	2006-02-15 05:09:17
4053	882	1	2006-02-15 05:09:17
4054	882	1	2006-02-15 05:09:17
4055	882	1	2006-02-15 05:09:17
4056	883	2	2006-02-15 05:09:17
4057	883	2	2006-02-15 05:09:17
4058	884	2	2006-02-15 05:09:17
4059	884	2	2006-02-15 05:09:17
4060	884	2	2006-02-15 05:09:17
4061	885	1	2006-02-15 05:09:17
4062	885	1	2006-02-15 05:09:17
4063	886	1	2006-02-15 05:09:17
4064	886	1	2006-02-15 05:09:17
4065	886	1	2006-02-15 05:09:17
4066	886	1	2006-02-15 05:09:17
4067	887	1	2006-02-15 05:09:17
4068	887	1	2006-02-15 05:09:17
4069	887	1	2006-02-15 05:09:17
4070	887	1	2006-02-15 05:09:17
4071	887	2	2006-02-15 05:09:17
4072	887	2	2006-02-15 05:09:17
4073	888	1	2006-02-15 05:09:17
4074	888	1	2006-02-15 05:09:17
4075	888	1	2006-02-15 05:09:17
4076	888	1	2006-02-15 05:09:17
4077	889	1	2006-02-15 05:09:17
4078	889	1	2006-02-15 05:09:17
4079	889	1	2006-02-15 05:09:17
4080	890	1	2006-02-15 05:09:17
4081	890	1	2006-02-15 05:09:17
4082	890	1	2006-02-15 05:09:17
4083	890	2	2006-02-15 05:09:17
4084	890	2	2006-02-15 05:09:17
4085	890	2	2006-02-15 05:09:17
4086	890	2	2006-02-15 05:09:17
4087	891	1	2006-02-15 05:09:17
4088	891	1	2006-02-15 05:09:17
4089	891	1	2006-02-15 05:09:17
4090	891	2	2006-02-15 05:09:17
4091	891	2	2006-02-15 05:09:17
4092	891	2	2006-02-15 05:09:17
4093	891	2	2006-02-15 05:09:17
4094	892	1	2006-02-15 05:09:17
4095	892	1	2006-02-15 05:09:17
4096	892	1	2006-02-15 05:09:17
4097	892	2	2006-02-15 05:09:17
4098	892	2	2006-02-15 05:09:17
4099	892	2	2006-02-15 05:09:17
4100	892	2	2006-02-15 05:09:17
4101	893	1	2006-02-15 05:09:17
4102	893	1	2006-02-15 05:09:17
4103	893	1	2006-02-15 05:09:17
4104	893	1	2006-02-15 05:09:17
4105	893	2	2006-02-15 05:09:17
4106	893	2	2006-02-15 05:09:17
4107	893	2	2006-02-15 05:09:17
4108	893	2	2006-02-15 05:09:17
4109	894	1	2006-02-15 05:09:17
4110	894	1	2006-02-15 05:09:17
4111	894	1	2006-02-15 05:09:17
4112	894	2	2006-02-15 05:09:17
4113	894	2	2006-02-15 05:09:17
4114	895	1	2006-02-15 05:09:17
4115	895	1	2006-02-15 05:09:17
4116	895	1	2006-02-15 05:09:17
4117	895	1	2006-02-15 05:09:17
4118	895	2	2006-02-15 05:09:17
4119	895	2	2006-02-15 05:09:17
4120	895	2	2006-02-15 05:09:17
4121	896	1	2006-02-15 05:09:17
4122	896	1	2006-02-15 05:09:17
4123	896	2	2006-02-15 05:09:17
4124	896	2	2006-02-15 05:09:17
4125	897	1	2006-02-15 05:09:17
4126	897	1	2006-02-15 05:09:17
4127	897	1	2006-02-15 05:09:17
4128	897	1	2006-02-15 05:09:17
4129	897	2	2006-02-15 05:09:17
4130	897	2	2006-02-15 05:09:17
4131	897	2	2006-02-15 05:09:17
4132	897	2	2006-02-15 05:09:17
4133	898	1	2006-02-15 05:09:17
4134	898	1	2006-02-15 05:09:17
4135	898	1	2006-02-15 05:09:17
4136	898	2	2006-02-15 05:09:17
4137	898	2	2006-02-15 05:09:17
4138	899	1	2006-02-15 05:09:17
4139	899	1	2006-02-15 05:09:17
4140	899	1	2006-02-15 05:09:17
4141	900	1	2006-02-15 05:09:17
4142	900	1	2006-02-15 05:09:17
4143	900	2	2006-02-15 05:09:17
4144	900	2	2006-02-15 05:09:17
4145	901	1	2006-02-15 05:09:17
4146	901	1	2006-02-15 05:09:17
4147	901	1	2006-02-15 05:09:17
4148	901	1	2006-02-15 05:09:17
4149	901	2	2006-02-15 05:09:17
4150	901	2	2006-02-15 05:09:17
4151	901	2	2006-02-15 05:09:17
4152	902	1	2006-02-15 05:09:17
4153	902	1	2006-02-15 05:09:17
4154	902	1	2006-02-15 05:09:17
4155	902	1	2006-02-15 05:09:17
4156	902	2	2006-02-15 05:09:17
4157	902	2	2006-02-15 05:09:17
4158	902	2	2006-02-15 05:09:17
4159	903	2	2006-02-15 05:09:17
4160	903	2	2006-02-15 05:09:17
4161	904	1	2006-02-15 05:09:17
4162	904	1	2006-02-15 05:09:17
4163	905	1	2006-02-15 05:09:17
4164	905	1	2006-02-15 05:09:17
4165	905	1	2006-02-15 05:09:17
4166	906	1	2006-02-15 05:09:17
4167	906	1	2006-02-15 05:09:17
4168	906	2	2006-02-15 05:09:17
4169	906	2	2006-02-15 05:09:17
4170	906	2	2006-02-15 05:09:17
4171	907	1	2006-02-15 05:09:17
4172	907	1	2006-02-15 05:09:17
4173	907	1	2006-02-15 05:09:17
4174	907	1	2006-02-15 05:09:17
4175	908	1	2006-02-15 05:09:17
4176	908	1	2006-02-15 05:09:17
4177	908	2	2006-02-15 05:09:17
4178	908	2	2006-02-15 05:09:17
4179	910	2	2006-02-15 05:09:17
4180	910	2	2006-02-15 05:09:17
4181	911	1	2006-02-15 05:09:17
4182	911	1	2006-02-15 05:09:17
4183	911	1	2006-02-15 05:09:17
4184	911	1	2006-02-15 05:09:17
4185	911	2	2006-02-15 05:09:17
4186	911	2	2006-02-15 05:09:17
4187	911	2	2006-02-15 05:09:17
4188	911	2	2006-02-15 05:09:17
4189	912	1	2006-02-15 05:09:17
4190	912	1	2006-02-15 05:09:17
4191	912	1	2006-02-15 05:09:17
4192	912	2	2006-02-15 05:09:17
4193	912	2	2006-02-15 05:09:17
4194	912	2	2006-02-15 05:09:17
4195	913	1	2006-02-15 05:09:17
4196	913	1	2006-02-15 05:09:17
4197	913	1	2006-02-15 05:09:17
4198	913	1	2006-02-15 05:09:17
4199	913	2	2006-02-15 05:09:17
4200	913	2	2006-02-15 05:09:17
4201	914	1	2006-02-15 05:09:17
4202	914	1	2006-02-15 05:09:17
4203	914	2	2006-02-15 05:09:17
4204	914	2	2006-02-15 05:09:17
4205	914	2	2006-02-15 05:09:17
4206	914	2	2006-02-15 05:09:17
4207	915	1	2006-02-15 05:09:17
4208	915	1	2006-02-15 05:09:17
4209	915	1	2006-02-15 05:09:17
4210	915	1	2006-02-15 05:09:17
4211	915	2	2006-02-15 05:09:17
4212	915	2	2006-02-15 05:09:17
4213	916	1	2006-02-15 05:09:17
4214	916	1	2006-02-15 05:09:17
4215	916	2	2006-02-15 05:09:17
4216	916	2	2006-02-15 05:09:17
4217	917	1	2006-02-15 05:09:17
4218	917	1	2006-02-15 05:09:17
4219	917	1	2006-02-15 05:09:17
4220	917	2	2006-02-15 05:09:17
4221	917	2	2006-02-15 05:09:17
4222	918	2	2006-02-15 05:09:17
4223	918	2	2006-02-15 05:09:17
4224	918	2	2006-02-15 05:09:17
4225	918	2	2006-02-15 05:09:17
4226	919	1	2006-02-15 05:09:17
4227	919	1	2006-02-15 05:09:17
4228	919	1	2006-02-15 05:09:17
4229	919	1	2006-02-15 05:09:17
4230	920	1	2006-02-15 05:09:17
4231	920	1	2006-02-15 05:09:17
4232	920	1	2006-02-15 05:09:17
4233	920	2	2006-02-15 05:09:17
4234	920	2	2006-02-15 05:09:17
4235	921	1	2006-02-15 05:09:17
4236	921	1	2006-02-15 05:09:17
4237	921	2	2006-02-15 05:09:17
4238	921	2	2006-02-15 05:09:17
4239	922	1	2006-02-15 05:09:17
4240	922	1	2006-02-15 05:09:17
4241	922	1	2006-02-15 05:09:17
4242	922	2	2006-02-15 05:09:17
4243	922	2	2006-02-15 05:09:17
4244	922	2	2006-02-15 05:09:17
4245	922	2	2006-02-15 05:09:17
4246	923	2	2006-02-15 05:09:17
4247	923	2	2006-02-15 05:09:17
4248	923	2	2006-02-15 05:09:17
4249	924	1	2006-02-15 05:09:17
4250	924	1	2006-02-15 05:09:17
4251	924	2	2006-02-15 05:09:17
4252	924	2	2006-02-15 05:09:17
4253	924	2	2006-02-15 05:09:17
4254	925	1	2006-02-15 05:09:17
4255	925	1	2006-02-15 05:09:17
4256	925	1	2006-02-15 05:09:17
4257	925	2	2006-02-15 05:09:17
4258	925	2	2006-02-15 05:09:17
4259	926	2	2006-02-15 05:09:17
4260	926	2	2006-02-15 05:09:17
4261	927	1	2006-02-15 05:09:17
4262	927	1	2006-02-15 05:09:17
4263	927	1	2006-02-15 05:09:17
4264	927	1	2006-02-15 05:09:17
4265	928	1	2006-02-15 05:09:17
4266	928	1	2006-02-15 05:09:17
4267	928	1	2006-02-15 05:09:17
4268	929	1	2006-02-15 05:09:17
4269	929	1	2006-02-15 05:09:17
4270	929	1	2006-02-15 05:09:17
4271	929	1	2006-02-15 05:09:17
4272	930	1	2006-02-15 05:09:17
4273	930	1	2006-02-15 05:09:17
4274	930	1	2006-02-15 05:09:17
4275	930	2	2006-02-15 05:09:17
4276	930	2	2006-02-15 05:09:17
4277	930	2	2006-02-15 05:09:17
4278	931	2	2006-02-15 05:09:17
4279	931	2	2006-02-15 05:09:17
4280	931	2	2006-02-15 05:09:17
4281	932	1	2006-02-15 05:09:17
4282	932	1	2006-02-15 05:09:17
4283	932	2	2006-02-15 05:09:17
4284	932	2	2006-02-15 05:09:17
4285	933	1	2006-02-15 05:09:17
4286	933	1	2006-02-15 05:09:17
4287	933	1	2006-02-15 05:09:17
4288	934	2	2006-02-15 05:09:17
4289	934	2	2006-02-15 05:09:17
4290	934	2	2006-02-15 05:09:17
4291	935	2	2006-02-15 05:09:17
4292	935	2	2006-02-15 05:09:17
4293	936	1	2006-02-15 05:09:17
4294	936	1	2006-02-15 05:09:17
4295	936	2	2006-02-15 05:09:17
4296	936	2	2006-02-15 05:09:17
4297	936	2	2006-02-15 05:09:17
4298	936	2	2006-02-15 05:09:17
4299	937	1	2006-02-15 05:09:17
4300	937	1	2006-02-15 05:09:17
4301	937	2	2006-02-15 05:09:17
4302	937	2	2006-02-15 05:09:17
4303	937	2	2006-02-15 05:09:17
4304	938	1	2006-02-15 05:09:17
4305	938	1	2006-02-15 05:09:17
4306	938	1	2006-02-15 05:09:17
4307	938	1	2006-02-15 05:09:17
4308	938	2	2006-02-15 05:09:17
4309	938	2	2006-02-15 05:09:17
4310	939	2	2006-02-15 05:09:17
4311	939	2	2006-02-15 05:09:17
4312	939	2	2006-02-15 05:09:17
4313	939	2	2006-02-15 05:09:17
4314	940	1	2006-02-15 05:09:17
4315	940	1	2006-02-15 05:09:17
4316	940	1	2006-02-15 05:09:17
4317	941	1	2006-02-15 05:09:17
4318	941	1	2006-02-15 05:09:17
4319	941	1	2006-02-15 05:09:17
4320	941	1	2006-02-15 05:09:17
4321	941	2	2006-02-15 05:09:17
4322	941	2	2006-02-15 05:09:17
4323	941	2	2006-02-15 05:09:17
4324	942	1	2006-02-15 05:09:17
4325	942	1	2006-02-15 05:09:17
4326	942	2	2006-02-15 05:09:17
4327	942	2	2006-02-15 05:09:17
4328	944	1	2006-02-15 05:09:17
4329	944	1	2006-02-15 05:09:17
4330	944	2	2006-02-15 05:09:17
4331	944	2	2006-02-15 05:09:17
4332	944	2	2006-02-15 05:09:17
4333	945	1	2006-02-15 05:09:17
4334	945	1	2006-02-15 05:09:17
4335	945	1	2006-02-15 05:09:17
4336	945	1	2006-02-15 05:09:17
4337	945	2	2006-02-15 05:09:17
4338	945	2	2006-02-15 05:09:17
4339	945	2	2006-02-15 05:09:17
4340	945	2	2006-02-15 05:09:17
4341	946	2	2006-02-15 05:09:17
4342	946	2	2006-02-15 05:09:17
4343	946	2	2006-02-15 05:09:17
4344	946	2	2006-02-15 05:09:17
4345	947	1	2006-02-15 05:09:17
4346	947	1	2006-02-15 05:09:17
4347	948	1	2006-02-15 05:09:17
4348	948	1	2006-02-15 05:09:17
4349	948	2	2006-02-15 05:09:17
4350	948	2	2006-02-15 05:09:17
4351	948	2	2006-02-15 05:09:17
4352	948	2	2006-02-15 05:09:17
4353	949	1	2006-02-15 05:09:17
4354	949	1	2006-02-15 05:09:17
4355	949	1	2006-02-15 05:09:17
4356	949	1	2006-02-15 05:09:17
4357	949	2	2006-02-15 05:09:17
4358	949	2	2006-02-15 05:09:17
4359	951	1	2006-02-15 05:09:17
4360	951	1	2006-02-15 05:09:17
4361	951	1	2006-02-15 05:09:17
4362	951	2	2006-02-15 05:09:17
4363	951	2	2006-02-15 05:09:17
4364	951	2	2006-02-15 05:09:17
4365	951	2	2006-02-15 05:09:17
4366	952	1	2006-02-15 05:09:17
4367	952	1	2006-02-15 05:09:17
4368	952	1	2006-02-15 05:09:17
4369	953	1	2006-02-15 05:09:17
4370	953	1	2006-02-15 05:09:17
4371	953	1	2006-02-15 05:09:17
4372	953	1	2006-02-15 05:09:17
4373	953	2	2006-02-15 05:09:17
4374	953	2	2006-02-15 05:09:17
4375	956	1	2006-02-15 05:09:17
4376	956	1	2006-02-15 05:09:17
4377	956	1	2006-02-15 05:09:17
4378	956	1	2006-02-15 05:09:17
4379	957	1	2006-02-15 05:09:17
4380	957	1	2006-02-15 05:09:17
4381	957	1	2006-02-15 05:09:17
4382	957	2	2006-02-15 05:09:17
4383	957	2	2006-02-15 05:09:17
4384	958	1	2006-02-15 05:09:17
4385	958	1	2006-02-15 05:09:17
4386	958	1	2006-02-15 05:09:17
4387	958	2	2006-02-15 05:09:17
4388	958	2	2006-02-15 05:09:17
4389	958	2	2006-02-15 05:09:17
4390	959	1	2006-02-15 05:09:17
4391	959	1	2006-02-15 05:09:17
4392	960	2	2006-02-15 05:09:17
4393	960	2	2006-02-15 05:09:17
4394	960	2	2006-02-15 05:09:17
4395	961	1	2006-02-15 05:09:17
4396	961	1	2006-02-15 05:09:17
4397	961	1	2006-02-15 05:09:17
4398	961	2	2006-02-15 05:09:17
4399	961	2	2006-02-15 05:09:17
4400	962	1	2006-02-15 05:09:17
4401	962	1	2006-02-15 05:09:17
4402	962	1	2006-02-15 05:09:17
4403	962	1	2006-02-15 05:09:17
4404	963	1	2006-02-15 05:09:17
4405	963	1	2006-02-15 05:09:17
4406	963	2	2006-02-15 05:09:17
4407	963	2	2006-02-15 05:09:17
4408	963	2	2006-02-15 05:09:17
4409	964	1	2006-02-15 05:09:17
4410	964	1	2006-02-15 05:09:17
4411	964	1	2006-02-15 05:09:17
4412	964	2	2006-02-15 05:09:17
4413	964	2	2006-02-15 05:09:17
4414	965	1	2006-02-15 05:09:17
4415	965	1	2006-02-15 05:09:17
4416	966	1	2006-02-15 05:09:17
4417	966	1	2006-02-15 05:09:17
4418	966	2	2006-02-15 05:09:17
4419	966	2	2006-02-15 05:09:17
4420	966	2	2006-02-15 05:09:17
4421	966	2	2006-02-15 05:09:17
4422	967	1	2006-02-15 05:09:17
4423	967	1	2006-02-15 05:09:17
4424	967	1	2006-02-15 05:09:17
4425	967	2	2006-02-15 05:09:17
4426	967	2	2006-02-15 05:09:17
4427	968	1	2006-02-15 05:09:17
4428	968	1	2006-02-15 05:09:17
4429	968	1	2006-02-15 05:09:17
4430	969	1	2006-02-15 05:09:17
4431	969	1	2006-02-15 05:09:17
4432	969	1	2006-02-15 05:09:17
4433	969	1	2006-02-15 05:09:17
4434	970	1	2006-02-15 05:09:17
4435	970	1	2006-02-15 05:09:17
4436	970	1	2006-02-15 05:09:17
4437	970	2	2006-02-15 05:09:17
4438	970	2	2006-02-15 05:09:17
4439	970	2	2006-02-15 05:09:17
4440	970	2	2006-02-15 05:09:17
4441	971	1	2006-02-15 05:09:17
4442	971	1	2006-02-15 05:09:17
4443	971	1	2006-02-15 05:09:17
4444	971	1	2006-02-15 05:09:17
4445	972	1	2006-02-15 05:09:17
4446	972	1	2006-02-15 05:09:17
4447	972	1	2006-02-15 05:09:17
4448	972	2	2006-02-15 05:09:17
4449	972	2	2006-02-15 05:09:17
4450	972	2	2006-02-15 05:09:17
4451	973	1	2006-02-15 05:09:17
4452	973	1	2006-02-15 05:09:17
4453	973	1	2006-02-15 05:09:17
4454	973	1	2006-02-15 05:09:17
4455	973	2	2006-02-15 05:09:17
4456	973	2	2006-02-15 05:09:17
4457	973	2	2006-02-15 05:09:17
4458	973	2	2006-02-15 05:09:17
4459	974	1	2006-02-15 05:09:17
4460	974	1	2006-02-15 05:09:17
4461	975	1	2006-02-15 05:09:17
4462	975	1	2006-02-15 05:09:17
4463	975	2	2006-02-15 05:09:17
4464	975	2	2006-02-15 05:09:17
4465	975	2	2006-02-15 05:09:17
4466	976	1	2006-02-15 05:09:17
4467	976	1	2006-02-15 05:09:17
4468	976	2	2006-02-15 05:09:17
4469	976	2	2006-02-15 05:09:17
4470	976	2	2006-02-15 05:09:17
4471	976	2	2006-02-15 05:09:17
4472	977	2	2006-02-15 05:09:17
4473	977	2	2006-02-15 05:09:17
4474	977	2	2006-02-15 05:09:17
4475	978	1	2006-02-15 05:09:17
4476	978	1	2006-02-15 05:09:17
4477	978	1	2006-02-15 05:09:17
4478	979	1	2006-02-15 05:09:17
4479	979	1	2006-02-15 05:09:17
4480	979	1	2006-02-15 05:09:17
4481	979	1	2006-02-15 05:09:17
4482	979	2	2006-02-15 05:09:17
4483	979	2	2006-02-15 05:09:17
4484	979	2	2006-02-15 05:09:17
4485	980	1	2006-02-15 05:09:17
4486	980	1	2006-02-15 05:09:17
4487	980	1	2006-02-15 05:09:17
4488	980	2	2006-02-15 05:09:17
4489	980	2	2006-02-15 05:09:17
4490	981	1	2006-02-15 05:09:17
4491	981	1	2006-02-15 05:09:17
4492	981	1	2006-02-15 05:09:17
4493	981	2	2006-02-15 05:09:17
4494	981	2	2006-02-15 05:09:17
4495	981	2	2006-02-15 05:09:17
4496	982	1	2006-02-15 05:09:17
4497	982	1	2006-02-15 05:09:17
4498	982	1	2006-02-15 05:09:17
4499	982	2	2006-02-15 05:09:17
4500	982	2	2006-02-15 05:09:17
4501	982	2	2006-02-15 05:09:17
4502	982	2	2006-02-15 05:09:17
4503	983	1	2006-02-15 05:09:17
4504	983	1	2006-02-15 05:09:17
4505	983	1	2006-02-15 05:09:17
4506	984	1	2006-02-15 05:09:17
4507	984	1	2006-02-15 05:09:17
4508	985	1	2006-02-15 05:09:17
4509	985	1	2006-02-15 05:09:17
4510	985	1	2006-02-15 05:09:17
4511	985	1	2006-02-15 05:09:17
4512	985	2	2006-02-15 05:09:17
4513	985	2	2006-02-15 05:09:17
4514	985	2	2006-02-15 05:09:17
4515	986	1	2006-02-15 05:09:17
4516	986	1	2006-02-15 05:09:17
4517	986	1	2006-02-15 05:09:17
4518	986	1	2006-02-15 05:09:17
4519	986	2	2006-02-15 05:09:17
4520	986	2	2006-02-15 05:09:17
4521	987	1	2006-02-15 05:09:17
4522	987	1	2006-02-15 05:09:17
4523	987	2	2006-02-15 05:09:17
4524	987	2	2006-02-15 05:09:17
4525	988	1	2006-02-15 05:09:17
4526	988	1	2006-02-15 05:09:17
4527	988	1	2006-02-15 05:09:17
4528	988	2	2006-02-15 05:09:17
4529	988	2	2006-02-15 05:09:17
4530	989	1	2006-02-15 05:09:17
4531	989	1	2006-02-15 05:09:17
4532	989	1	2006-02-15 05:09:17
4533	989	1	2006-02-15 05:09:17
4534	989	2	2006-02-15 05:09:17
4535	989	2	2006-02-15 05:09:17
4536	990	2	2006-02-15 05:09:17
4537	990	2	2006-02-15 05:09:17
4538	991	1	2006-02-15 05:09:17
4539	991	1	2006-02-15 05:09:17
4540	991	2	2006-02-15 05:09:17
4541	991	2	2006-02-15 05:09:17
4542	991	2	2006-02-15 05:09:17
4543	992	2	2006-02-15 05:09:17
4544	992	2	2006-02-15 05:09:17
4545	992	2	2006-02-15 05:09:17
4546	992	2	2006-02-15 05:09:17
4547	993	1	2006-02-15 05:09:17
4548	993	1	2006-02-15 05:09:17
4549	993	1	2006-02-15 05:09:17
4550	993	1	2006-02-15 05:09:17
4551	993	2	2006-02-15 05:09:17
4552	993	2	2006-02-15 05:09:17
4553	993	2	2006-02-15 05:09:17
4554	994	1	2006-02-15 05:09:17
4555	994	1	2006-02-15 05:09:17
4556	994	1	2006-02-15 05:09:17
4557	995	1	2006-02-15 05:09:17
4558	995	1	2006-02-15 05:09:17
4559	995	1	2006-02-15 05:09:17
4560	995	1	2006-02-15 05:09:17
4561	995	2	2006-02-15 05:09:17
4562	995	2	2006-02-15 05:09:17
4563	996	1	2006-02-15 05:09:17
4564	996	1	2006-02-15 05:09:17
4565	997	1	2006-02-15 05:09:17
4566	997	1	2006-02-15 05:09:17
4567	998	2	2006-02-15 05:09:17
4568	998	2	2006-02-15 05:09:17
4569	999	1	2006-02-15 05:09:17
4570	999	1	2006-02-15 05:09:17
4571	999	2	2006-02-15 05:09:17
4572	999	2	2006-02-15 05:09:17
4573	999	2	2006-02-15 05:09:17
4574	1000	1	2006-02-15 05:09:17
4575	1000	1	2006-02-15 05:09:17
4576	1000	1	2006-02-15 05:09:17
4577	1000	1	2006-02-15 05:09:17
4578	1000	2	2006-02-15 05:09:17
4579	1000	2	2006-02-15 05:09:17
4580	1000	2	2006-02-15 05:09:17
4581	1000	2	2006-02-15 05:09:17
\.


--
-- Data for Name: language; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.language (language_id, name, last_update) FROM stdin;
1	English             	2006-02-15 05:02:19
2	Italian             	2006-02-15 05:02:19
3	Japanese            	2006-02-15 05:02:19
4	Mandarin            	2006-02-15 05:02:19
5	French              	2006-02-15 05:02:19
6	German              	2006-02-15 05:02:19
\.


--
-- Data for Name: payment; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.payment (payment_id, customer_id, staff_id, rental_id, amount, payment_date) FROM stdin;
\.


--
-- Data for Name: payment_p2007_01; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.payment_p2007_01 (payment_id, customer_id, staff_id, rental_id, amount, payment_date) FROM stdin;
\.


--
-- Data for Name: payment_p2007_02; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.payment_p2007_02 (payment_id, customer_id, staff_id, rental_id, amount, payment_date) FROM stdin;
\.


--
-- Data for Name: payment_p2007_03; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.payment_p2007_03 (payment_id, customer_id, staff_id, rental_id, amount, payment_date) FROM stdin;
\.


--
-- Data for Name: payment_p2007_04; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.payment_p2007_04 (payment_id, customer_id, staff_id, rental_id, amount, payment_date) FROM stdin;
\.


--
-- Data for Name: payment_p2007_05; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.payment_p2007_05 (payment_id, customer_id, staff_id, rental_id, amount, payment_date) FROM stdin;
\.


--
-- Data for Name: payment_p2007_06; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.payment_p2007_06 (payment_id, customer_id, staff_id, rental_id, amount, payment_date) FROM stdin;
\.


--
-- Data for Name: rental; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.rental (rental_id, rental_date, inventory_id, customer_id, return_date, staff_id, last_update) FROM stdin;
1	2005-05-24 22:53:30	367	130	2005-05-26 22:04:30	1	2006-02-15 21:30:53
2	2005-05-24 22:54:33	1525	459	2005-05-28 19:40:33	1	2006-02-15 21:30:53
3	2005-05-24 23:03:39	1711	408	2005-06-01 22:12:39	1	2006-02-15 21:30:53
4	2005-05-24 23:04:41	2452	333	2005-06-03 01:43:41	2	2006-02-15 21:30:53
5	2005-05-24 23:05:21	2079	222	2005-06-02 04:33:21	1	2006-02-15 21:30:53
6	2005-05-24 23:08:07	2792	549	2005-05-27 01:32:07	1	2006-02-15 21:30:53
7	2005-05-24 23:11:53	3995	269	2005-05-29 20:34:53	2	2006-02-15 21:30:53
8	2005-05-24 23:31:46	2346	239	2005-05-27 23:33:46	2	2006-02-15 21:30:53
9	2005-05-25 00:00:40	2580	126	2005-05-28 00:22:40	1	2006-02-15 21:30:53
10	2005-05-25 00:02:21	1824	399	2005-05-31 22:44:21	2	2006-02-15 21:30:53
11	2005-05-25 00:09:02	4443	142	2005-06-02 20:56:02	2	2006-02-15 21:30:53
12	2005-05-25 00:19:27	1584	261	2005-05-30 05:44:27	2	2006-02-15 21:30:53
13	2005-05-25 00:22:55	2294	334	2005-05-30 04:28:55	1	2006-02-15 21:30:53
14	2005-05-25 00:31:15	2701	446	2005-05-26 02:56:15	1	2006-02-15 21:30:53
15	2005-05-25 00:39:22	3049	319	2005-06-03 03:30:22	1	2006-02-15 21:30:53
16	2005-05-25 00:43:11	389	316	2005-05-26 04:42:11	2	2006-02-15 21:30:53
17	2005-05-25 01:06:36	830	575	2005-05-27 00:43:36	1	2006-02-15 21:30:53
18	2005-05-25 01:10:47	3376	19	2005-05-31 06:35:47	2	2006-02-15 21:30:53
19	2005-05-25 01:17:24	1941	456	2005-05-31 06:00:24	1	2006-02-15 21:30:53
20	2005-05-25 01:48:41	3517	185	2005-05-27 02:20:41	2	2006-02-15 21:30:53
21	2005-05-25 01:59:46	146	388	2005-05-26 01:01:46	2	2006-02-15 21:30:53
22	2005-05-25 02:19:23	727	509	2005-05-26 04:52:23	2	2006-02-15 21:30:53
23	2005-05-25 02:40:21	4441	438	2005-05-29 06:34:21	1	2006-02-15 21:30:53
24	2005-05-25 02:53:02	3273	350	2005-05-27 01:15:02	1	2006-02-15 21:30:53
25	2005-05-25 03:21:20	3961	37	2005-05-27 21:25:20	2	2006-02-15 21:30:53
26	2005-05-25 03:36:50	4371	371	2005-05-31 00:34:50	1	2006-02-15 21:30:53
27	2005-05-25 03:41:50	1225	301	2005-05-30 01:13:50	2	2006-02-15 21:30:53
28	2005-05-25 03:42:37	4068	232	2005-05-26 09:26:37	2	2006-02-15 21:30:53
29	2005-05-25 03:47:12	611	44	2005-05-30 00:31:12	2	2006-02-15 21:30:53
30	2005-05-25 04:01:32	3744	430	2005-05-30 03:12:32	1	2006-02-15 21:30:53
31	2005-05-25 04:05:17	4482	369	2005-05-30 07:15:17	1	2006-02-15 21:30:53
32	2005-05-25 04:06:21	3832	230	2005-05-25 23:55:21	1	2006-02-15 21:30:53
33	2005-05-25 04:18:51	1681	272	2005-05-27 03:58:51	1	2006-02-15 21:30:53
34	2005-05-25 04:19:28	2613	597	2005-05-29 00:10:28	2	2006-02-15 21:30:53
35	2005-05-25 04:24:36	1286	484	2005-05-27 07:02:36	2	2006-02-15 21:30:53
36	2005-05-25 04:36:26	1308	88	2005-05-29 00:31:26	1	2006-02-15 21:30:53
37	2005-05-25 04:44:31	403	535	2005-05-29 01:03:31	1	2006-02-15 21:30:53
38	2005-05-25 04:47:44	2540	302	2005-06-01 00:58:44	1	2006-02-15 21:30:53
39	2005-05-25 04:51:46	4466	207	2005-05-31 03:14:46	2	2006-02-15 21:30:53
40	2005-05-25 05:09:04	2638	413	2005-05-27 23:12:04	1	2006-02-15 21:30:53
41	2005-05-25 05:12:29	1761	174	2005-06-02 00:28:29	1	2006-02-15 21:30:53
42	2005-05-25 05:24:58	380	523	2005-05-31 02:47:58	2	2006-02-15 21:30:53
43	2005-05-25 05:39:25	2578	532	2005-05-26 06:54:25	2	2006-02-15 21:30:53
44	2005-05-25 05:53:23	3098	207	2005-05-29 10:56:23	2	2006-02-15 21:30:53
45	2005-05-25 05:59:39	1853	436	2005-06-02 09:56:39	2	2006-02-15 21:30:53
46	2005-05-25 06:04:08	3318	7	2005-06-02 08:18:08	2	2006-02-15 21:30:53
47	2005-05-25 06:05:20	2211	35	2005-05-30 03:04:20	1	2006-02-15 21:30:53
48	2005-05-25 06:20:46	1780	282	2005-06-02 05:42:46	1	2006-02-15 21:30:53
49	2005-05-25 06:39:35	2965	498	2005-05-30 10:12:35	2	2006-02-15 21:30:53
50	2005-05-25 06:44:53	1983	18	2005-05-28 11:28:53	2	2006-02-15 21:30:53
51	2005-05-25 06:49:10	1257	256	2005-05-26 06:42:10	1	2006-02-15 21:30:53
52	2005-05-25 06:51:29	4017	507	2005-05-31 01:27:29	2	2006-02-15 21:30:53
53	2005-05-25 07:19:16	1255	569	2005-05-27 05:19:16	2	2006-02-15 21:30:53
54	2005-05-25 07:23:25	2787	291	2005-06-01 05:05:25	2	2006-02-15 21:30:53
55	2005-05-25 08:26:13	1139	131	2005-05-30 10:57:13	1	2006-02-15 21:30:53
56	2005-05-25 08:28:11	1352	511	2005-05-26 14:21:11	1	2006-02-15 21:30:53
57	2005-05-25 08:43:32	3938	6	2005-05-29 06:42:32	2	2006-02-15 21:30:53
58	2005-05-25 08:53:14	3050	323	2005-05-28 14:40:14	1	2006-02-15 21:30:53
59	2005-05-25 08:56:42	2884	408	2005-06-01 09:52:42	1	2006-02-15 21:30:53
60	2005-05-25 08:58:25	330	470	2005-05-30 14:14:25	1	2006-02-15 21:30:53
61	2005-05-25 09:01:57	4210	250	2005-06-02 07:22:57	2	2006-02-15 21:30:53
62	2005-05-25 09:18:52	261	419	2005-05-30 10:55:52	1	2006-02-15 21:30:53
63	2005-05-25 09:19:16	4008	383	2005-05-27 04:24:16	1	2006-02-15 21:30:53
64	2005-05-25 09:21:29	79	368	2005-06-03 11:31:29	1	2006-02-15 21:30:53
65	2005-05-25 09:32:03	3552	346	2005-05-29 14:21:03	1	2006-02-15 21:30:53
66	2005-05-25 09:35:12	1162	86	2005-05-29 04:16:12	2	2006-02-15 21:30:53
67	2005-05-25 09:41:01	239	119	2005-05-27 13:46:01	2	2006-02-15 21:30:53
68	2005-05-25 09:47:31	4029	120	2005-05-31 10:20:31	2	2006-02-15 21:30:53
69	2005-05-25 10:10:14	3207	305	2005-05-27 14:02:14	2	2006-02-15 21:30:53
70	2005-05-25 10:15:23	2168	73	2005-05-27 05:56:23	2	2006-02-15 21:30:53
71	2005-05-25 10:26:39	2408	100	2005-05-28 04:59:39	1	2006-02-15 21:30:53
72	2005-05-25 10:52:13	2260	48	2005-05-28 05:52:13	2	2006-02-15 21:30:53
73	2005-05-25 11:00:07	517	391	2005-06-01 13:56:07	2	2006-02-15 21:30:53
74	2005-05-25 11:09:48	1744	265	2005-05-26 12:23:48	2	2006-02-15 21:30:53
75	2005-05-25 11:13:34	3393	510	2005-06-03 12:58:34	1	2006-02-15 21:30:53
76	2005-05-25 11:30:37	3021	1	2005-06-03 12:00:37	2	2006-02-15 21:30:53
77	2005-05-25 11:31:59	1303	451	2005-05-26 16:53:59	2	2006-02-15 21:30:53
78	2005-05-25 11:35:18	4067	135	2005-05-31 12:48:18	2	2006-02-15 21:30:53
79	2005-05-25 12:11:07	3299	245	2005-06-03 10:54:07	2	2006-02-15 21:30:53
80	2005-05-25 12:12:07	2478	314	2005-05-31 17:46:07	2	2006-02-15 21:30:53
81	2005-05-25 12:15:19	2610	286	2005-06-02 14:08:19	2	2006-02-15 21:30:53
82	2005-05-25 12:17:46	1388	427	2005-06-01 10:48:46	1	2006-02-15 21:30:53
83	2005-05-25 12:30:15	466	131	2005-05-27 15:40:15	1	2006-02-15 21:30:53
84	2005-05-25 12:36:30	1829	492	2005-05-29 18:33:30	1	2006-02-15 21:30:53
85	2005-05-25 13:05:34	470	414	2005-05-29 16:53:34	1	2006-02-15 21:30:53
86	2005-05-25 13:36:12	2275	266	2005-05-30 14:53:12	1	2006-02-15 21:30:53
87	2005-05-25 13:52:43	1586	331	2005-05-29 11:12:43	2	2006-02-15 21:30:53
88	2005-05-25 14:13:54	2221	53	2005-05-29 09:32:54	2	2006-02-15 21:30:53
89	2005-05-25 14:28:29	2181	499	2005-05-29 14:33:29	1	2006-02-15 21:30:53
90	2005-05-25 14:31:25	2984	25	2005-06-01 10:07:25	1	2006-02-15 21:30:53
91	2005-05-25 14:57:22	139	267	2005-06-01 18:32:22	1	2006-02-15 21:30:53
92	2005-05-25 15:38:46	775	302	2005-05-31 13:40:46	2	2006-02-15 21:30:53
93	2005-05-25 15:54:16	4360	288	2005-06-03 20:18:16	1	2006-02-15 21:30:53
94	2005-05-25 16:03:42	1675	197	2005-05-30 14:23:42	1	2006-02-15 21:30:53
95	2005-05-25 16:12:52	178	400	2005-06-02 18:55:52	2	2006-02-15 21:30:53
96	2005-05-25 16:32:19	3418	49	2005-05-30 10:47:19	2	2006-02-15 21:30:53
97	2005-05-25 16:34:24	1283	263	2005-05-28 12:13:24	2	2006-02-15 21:30:53
98	2005-05-25 16:48:24	2970	269	2005-05-27 11:29:24	2	2006-02-15 21:30:53
99	2005-05-25 16:50:20	535	44	2005-05-28 18:52:20	1	2006-02-15 21:30:53
100	2005-05-25 16:50:28	2599	208	2005-06-02 22:11:28	1	2006-02-15 21:30:53
101	2005-05-25 17:17:04	617	468	2005-05-31 19:47:04	1	2006-02-15 21:30:53
102	2005-05-25 17:22:10	373	343	2005-05-31 19:47:10	1	2006-02-15 21:30:53
103	2005-05-25 17:30:42	3343	384	2005-06-03 22:36:42	1	2006-02-15 21:30:53
104	2005-05-25 17:46:33	4281	310	2005-05-27 15:20:33	1	2006-02-15 21:30:53
105	2005-05-25 17:54:12	794	108	2005-05-30 12:03:12	2	2006-02-15 21:30:53
106	2005-05-25 18:18:19	3627	196	2005-06-04 00:01:19	2	2006-02-15 21:30:53
107	2005-05-25 18:28:09	2833	317	2005-06-03 22:46:09	2	2006-02-15 21:30:53
108	2005-05-25 18:30:05	3289	242	2005-05-30 19:40:05	1	2006-02-15 21:30:53
109	2005-05-25 18:40:20	1044	503	2005-05-29 20:39:20	2	2006-02-15 21:30:53
110	2005-05-25 18:43:49	4108	19	2005-06-03 18:13:49	2	2006-02-15 21:30:53
111	2005-05-25 18:45:19	3725	227	2005-05-28 17:18:19	1	2006-02-15 21:30:53
112	2005-05-25 18:57:24	2153	500	2005-06-02 20:44:24	1	2006-02-15 21:30:53
113	2005-05-25 19:07:40	2963	93	2005-05-27 22:16:40	2	2006-02-15 21:30:53
114	2005-05-25 19:12:42	4502	506	2005-06-01 23:10:42	1	2006-02-15 21:30:53
115	2005-05-25 19:13:25	749	455	2005-05-29 20:17:25	1	2006-02-15 21:30:53
116	2005-05-25 19:27:51	4453	18	2005-05-26 16:23:51	1	2006-02-15 21:30:53
117	2005-05-25 19:30:46	4278	7	2005-05-31 23:59:46	2	2006-02-15 21:30:53
118	2005-05-25 19:31:18	872	524	2005-05-31 15:00:18	1	2006-02-15 21:30:53
119	2005-05-25 19:37:02	1359	51	2005-05-29 23:51:02	2	2006-02-15 21:30:53
120	2005-05-25 19:37:47	37	365	2005-06-01 23:29:47	2	2006-02-15 21:30:53
121	2005-05-25 19:41:29	1053	405	2005-05-29 21:31:29	1	2006-02-15 21:30:53
122	2005-05-25 19:46:21	2908	273	2005-06-02 19:07:21	1	2006-02-15 21:30:53
123	2005-05-25 20:26:42	1795	43	2005-05-26 19:41:42	1	2006-02-15 21:30:53
124	2005-05-25 20:46:11	212	246	2005-05-30 00:47:11	2	2006-02-15 21:30:53
125	2005-05-25 20:48:50	952	368	2005-06-02 21:39:50	1	2006-02-15 21:30:53
126	2005-05-25 21:07:59	2047	439	2005-05-28 18:51:59	1	2006-02-15 21:30:53
127	2005-05-25 21:10:40	2026	94	2005-06-02 21:38:40	1	2006-02-15 21:30:53
128	2005-05-25 21:19:53	4322	40	2005-05-29 23:34:53	1	2006-02-15 21:30:53
129	2005-05-25 21:20:03	4154	23	2005-06-04 01:25:03	2	2006-02-15 21:30:53
130	2005-05-25 21:21:56	3990	56	2005-05-30 22:41:56	2	2006-02-15 21:30:53
131	2005-05-25 21:42:46	815	325	2005-05-30 23:25:46	2	2006-02-15 21:30:53
132	2005-05-25 21:46:54	3367	479	2005-05-31 21:02:54	1	2006-02-15 21:30:53
133	2005-05-25 21:48:30	399	237	2005-05-30 00:26:30	2	2006-02-15 21:30:53
134	2005-05-25 21:48:41	2272	222	2005-06-02 18:28:41	1	2006-02-15 21:30:53
135	2005-05-25 21:58:58	103	304	2005-06-03 17:50:58	1	2006-02-15 21:30:53
136	2005-05-25 22:02:30	2296	504	2005-05-31 18:06:30	1	2006-02-15 21:30:53
137	2005-05-25 22:25:18	2591	560	2005-06-01 02:30:18	2	2006-02-15 21:30:53
138	2005-05-25 22:48:22	4134	586	2005-05-29 20:21:22	2	2006-02-15 21:30:53
139	2005-05-25 23:00:21	327	257	2005-05-29 17:12:21	1	2006-02-15 21:30:53
140	2005-05-25 23:34:22	655	354	2005-05-27 01:10:22	1	2006-02-15 21:30:53
141	2005-05-25 23:34:53	811	89	2005-06-02 01:57:53	1	2006-02-15 21:30:53
142	2005-05-25 23:43:47	4407	472	2005-05-29 00:46:47	2	2006-02-15 21:30:53
143	2005-05-25 23:45:52	847	297	2005-05-27 21:41:52	2	2006-02-15 21:30:53
144	2005-05-25 23:49:56	1689	357	2005-06-01 21:41:56	2	2006-02-15 21:30:53
145	2005-05-25 23:59:03	3905	82	2005-05-31 02:56:03	1	2006-02-15 21:30:53
146	2005-05-26 00:07:11	1431	433	2005-06-04 00:20:11	2	2006-02-15 21:30:53
147	2005-05-26 00:17:50	633	274	2005-05-29 23:21:50	2	2006-02-15 21:30:53
148	2005-05-26 00:25:23	4252	142	2005-06-01 19:29:23	2	2006-02-15 21:30:53
149	2005-05-26 00:28:05	1084	319	2005-06-02 21:30:05	2	2006-02-15 21:30:53
150	2005-05-26 00:28:39	909	429	2005-06-01 02:10:39	2	2006-02-15 21:30:53
151	2005-05-26 00:37:28	2942	14	2005-05-30 06:28:28	1	2006-02-15 21:30:53
152	2005-05-26 00:41:10	2622	57	2005-06-03 06:05:10	1	2006-02-15 21:30:53
153	2005-05-26 00:47:47	3888	348	2005-05-27 21:28:47	1	2006-02-15 21:30:53
154	2005-05-26 00:55:56	1354	185	2005-05-29 23:18:56	2	2006-02-15 21:30:53
155	2005-05-26 01:15:05	288	551	2005-06-01 00:03:05	1	2006-02-15 21:30:53
156	2005-05-26 01:19:05	3193	462	2005-05-27 23:43:05	1	2006-02-15 21:30:53
157	2005-05-26 01:25:21	887	344	2005-05-26 21:17:21	2	2006-02-15 21:30:53
158	2005-05-26 01:27:11	2395	354	2005-06-03 00:30:11	2	2006-02-15 21:30:53
159	2005-05-26 01:34:28	3453	505	2005-05-29 04:00:28	1	2006-02-15 21:30:53
160	2005-05-26 01:46:20	1885	290	2005-06-01 05:45:20	1	2006-02-15 21:30:53
161	2005-05-26 01:51:48	2941	182	2005-05-27 05:42:48	1	2006-02-15 21:30:53
162	2005-05-26 02:02:05	1229	296	2005-05-27 03:38:05	2	2006-02-15 21:30:53
163	2005-05-26 02:26:23	2306	104	2005-06-04 06:36:23	1	2006-02-15 21:30:53
164	2005-05-26 02:26:49	1070	151	2005-05-28 00:32:49	1	2006-02-15 21:30:53
165	2005-05-26 02:28:36	2735	33	2005-06-02 03:21:36	1	2006-02-15 21:30:53
166	2005-05-26 02:49:11	3894	322	2005-05-31 01:28:11	1	2006-02-15 21:30:53
167	2005-05-26 02:50:31	865	401	2005-05-27 03:07:31	1	2006-02-15 21:30:53
168	2005-05-26 03:07:43	2714	469	2005-06-02 02:09:43	2	2006-02-15 21:30:53
169	2005-05-26 03:09:30	1758	381	2005-05-27 01:37:30	2	2006-02-15 21:30:53
170	2005-05-26 03:11:12	3688	107	2005-06-02 03:53:12	1	2006-02-15 21:30:53
171	2005-05-26 03:14:15	4483	400	2005-06-03 00:24:15	2	2006-02-15 21:30:53
172	2005-05-26 03:17:42	2873	176	2005-05-29 04:11:42	2	2006-02-15 21:30:53
173	2005-05-26 03:42:10	3596	533	2005-05-28 01:37:10	2	2006-02-15 21:30:53
174	2005-05-26 03:44:10	3954	552	2005-05-28 07:13:10	2	2006-02-15 21:30:53
175	2005-05-26 03:46:26	4346	47	2005-06-03 06:01:26	2	2006-02-15 21:30:53
176	2005-05-26 03:47:39	851	250	2005-06-01 02:36:39	2	2006-02-15 21:30:53
177	2005-05-26 04:14:29	3545	548	2005-06-01 08:16:29	2	2006-02-15 21:30:53
178	2005-05-26 04:21:46	1489	196	2005-06-04 07:09:46	2	2006-02-15 21:30:53
179	2005-05-26 04:26:06	2575	19	2005-06-03 10:06:06	1	2006-02-15 21:30:53
180	2005-05-26 04:46:23	2752	75	2005-06-01 09:58:23	1	2006-02-15 21:30:53
181	2005-05-26 04:47:06	2417	587	2005-05-29 06:34:06	2	2006-02-15 21:30:53
182	2005-05-26 04:49:17	4396	237	2005-06-01 05:43:17	2	2006-02-15 21:30:53
183	2005-05-26 05:01:18	2877	254	2005-06-01 09:04:18	1	2006-02-15 21:30:53
184	2005-05-26 05:29:49	1970	556	2005-05-28 10:10:49	1	2006-02-15 21:30:53
185	2005-05-26 05:30:03	2598	125	2005-06-02 09:48:03	2	2006-02-15 21:30:53
186	2005-05-26 05:32:52	1799	468	2005-06-03 07:19:52	2	2006-02-15 21:30:53
187	2005-05-26 05:42:37	4004	515	2005-06-04 00:38:37	1	2006-02-15 21:30:53
188	2005-05-26 05:47:12	3342	243	2005-05-26 23:48:12	1	2006-02-15 21:30:53
189	2005-05-26 06:01:41	984	247	2005-05-27 06:11:41	1	2006-02-15 21:30:53
190	2005-05-26 06:11:28	3962	533	2005-06-01 09:44:28	1	2006-02-15 21:30:53
191	2005-05-26 06:14:06	4365	412	2005-05-28 05:33:06	1	2006-02-15 21:30:53
192	2005-05-26 06:20:37	1897	437	2005-06-02 10:57:37	1	2006-02-15 21:30:53
193	2005-05-26 06:41:48	3900	270	2005-05-30 06:21:48	2	2006-02-15 21:30:53
194	2005-05-26 06:52:33	1337	29	2005-05-30 04:08:33	2	2006-02-15 21:30:53
195	2005-05-26 06:52:36	506	564	2005-05-31 02:47:36	2	2006-02-15 21:30:53
196	2005-05-26 06:55:58	190	184	2005-05-27 10:54:58	1	2006-02-15 21:30:53
197	2005-05-26 06:59:21	4212	546	2005-06-03 05:04:21	2	2006-02-15 21:30:53
198	2005-05-26 07:03:49	1789	54	2005-06-04 11:45:49	1	2006-02-15 21:30:53
199	2005-05-26 07:11:58	2135	71	2005-05-28 09:06:58	1	2006-02-15 21:30:53
200	2005-05-26 07:12:21	3926	321	2005-05-31 12:07:21	1	2006-02-15 21:30:53
201	2005-05-26 07:13:45	776	444	2005-06-04 02:02:45	2	2006-02-15 21:30:53
202	2005-05-26 07:27:36	674	20	2005-06-02 03:52:36	1	2006-02-15 21:30:53
203	2005-05-26 07:27:57	3374	109	2005-06-03 12:52:57	1	2006-02-15 21:30:53
204	2005-05-26 07:30:37	1842	528	2005-05-30 08:11:37	1	2006-02-15 21:30:53
205	2005-05-26 07:59:37	303	114	2005-05-29 09:43:37	2	2006-02-15 21:30:53
206	2005-05-26 08:01:54	1717	345	2005-05-27 06:26:54	1	2006-02-15 21:30:53
207	2005-05-26 08:04:38	102	47	2005-05-27 09:32:38	2	2006-02-15 21:30:53
208	2005-05-26 08:10:22	3669	274	2005-05-27 03:55:22	1	2006-02-15 21:30:53
209	2005-05-26 08:14:01	729	379	2005-05-27 09:00:01	1	2006-02-15 21:30:53
210	2005-05-26 08:14:15	1801	391	2005-05-27 12:12:15	2	2006-02-15 21:30:53
211	2005-05-26 08:33:10	4005	170	2005-05-28 14:09:10	1	2006-02-15 21:30:53
212	2005-05-26 08:34:41	764	59	2005-05-30 12:46:41	2	2006-02-15 21:30:53
213	2005-05-26 08:44:08	1505	394	2005-05-31 12:33:08	2	2006-02-15 21:30:53
214	2005-05-26 08:48:49	1453	98	2005-05-31 04:06:49	2	2006-02-15 21:30:53
215	2005-05-26 09:02:47	679	197	2005-05-28 09:45:47	2	2006-02-15 21:30:53
216	2005-05-26 09:17:43	1398	91	2005-06-03 08:21:43	1	2006-02-15 21:30:53
217	2005-05-26 09:24:26	4395	121	2005-05-31 03:24:26	2	2006-02-15 21:30:53
218	2005-05-26 09:27:09	2291	309	2005-06-04 11:53:09	2	2006-02-15 21:30:53
219	2005-05-26 09:41:45	3074	489	2005-05-28 04:40:45	1	2006-02-15 21:30:53
220	2005-05-26 10:06:49	1259	542	2005-06-01 07:43:49	1	2006-02-15 21:30:53
221	2005-05-26 10:14:09	3578	143	2005-05-29 05:57:09	1	2006-02-15 21:30:53
222	2005-05-26 10:14:38	2745	83	2005-05-31 08:36:38	2	2006-02-15 21:30:53
223	2005-05-26 10:15:23	3121	460	2005-05-30 11:43:23	1	2006-02-15 21:30:53
224	2005-05-26 10:18:27	4285	318	2005-06-04 06:59:27	1	2006-02-15 21:30:53
225	2005-05-26 10:27:50	651	467	2005-06-01 07:01:50	2	2006-02-15 21:30:53
226	2005-05-26 10:44:04	4181	221	2005-05-31 13:26:04	2	2006-02-15 21:30:53
227	2005-05-26 10:51:46	214	301	2005-05-30 07:24:46	1	2006-02-15 21:30:53
228	2005-05-26 10:54:28	511	571	2005-06-04 09:39:28	1	2006-02-15 21:30:53
229	2005-05-26 11:19:20	1131	312	2005-05-31 11:56:20	2	2006-02-15 21:30:53
230	2005-05-26 11:31:50	1085	58	2005-05-30 15:22:50	1	2006-02-15 21:30:53
231	2005-05-26 11:31:59	4032	365	2005-05-27 07:27:59	1	2006-02-15 21:30:53
232	2005-05-26 11:38:05	2945	256	2005-05-27 08:42:05	2	2006-02-15 21:30:53
233	2005-05-26 11:43:44	715	531	2005-05-28 17:28:44	2	2006-02-15 21:30:53
234	2005-05-26 11:47:20	1321	566	2005-06-03 10:39:20	2	2006-02-15 21:30:53
235	2005-05-26 11:51:09	3537	119	2005-06-04 09:36:09	1	2006-02-15 21:30:53
236	2005-05-26 11:53:49	1265	446	2005-05-28 13:55:49	1	2006-02-15 21:30:53
237	2005-05-26 12:15:13	241	536	2005-05-29 18:10:13	1	2006-02-15 21:30:53
238	2005-05-26 12:30:22	503	211	2005-05-27 06:49:22	1	2006-02-15 21:30:53
239	2005-05-26 12:30:26	131	49	2005-06-01 13:26:26	2	2006-02-15 21:30:53
240	2005-05-26 12:40:23	3420	103	2005-06-04 07:22:23	1	2006-02-15 21:30:53
241	2005-05-26 12:49:01	4438	245	2005-05-28 11:43:01	2	2006-02-15 21:30:53
242	2005-05-26 13:05:08	2095	214	2005-06-02 15:26:08	1	2006-02-15 21:30:53
243	2005-05-26 13:06:05	1721	543	2005-06-03 17:28:05	2	2006-02-15 21:30:53
244	2005-05-26 13:40:40	1041	257	2005-05-31 11:58:40	1	2006-02-15 21:30:53
245	2005-05-26 13:46:59	3045	158	2005-05-27 09:58:59	2	2006-02-15 21:30:53
246	2005-05-26 13:57:07	2829	240	2005-05-29 10:12:07	2	2006-02-15 21:30:53
247	2005-05-26 14:01:05	4095	102	2005-05-28 13:38:05	2	2006-02-15 21:30:53
248	2005-05-26 14:07:58	1913	545	2005-05-31 14:03:58	2	2006-02-15 21:30:53
249	2005-05-26 14:19:09	2428	472	2005-05-28 17:47:09	2	2006-02-15 21:30:53
250	2005-05-26 14:30:24	368	539	2005-05-27 08:50:24	1	2006-02-15 21:30:53
251	2005-05-26 14:35:40	4352	204	2005-05-29 17:17:40	1	2006-02-15 21:30:53
252	2005-05-26 14:39:53	1203	187	2005-06-02 14:48:53	1	2006-02-15 21:30:53
253	2005-05-26 14:43:14	2969	416	2005-05-27 12:21:14	1	2006-02-15 21:30:53
254	2005-05-26 14:43:48	1835	390	2005-05-31 09:19:48	2	2006-02-15 21:30:53
255	2005-05-26 14:52:15	3264	114	2005-05-27 12:45:15	1	2006-02-15 21:30:53
256	2005-05-26 15:20:58	3194	436	2005-05-31 15:58:58	1	2006-02-15 21:30:53
257	2005-05-26 15:27:05	2570	373	2005-05-29 16:25:05	2	2006-02-15 21:30:53
258	2005-05-26 15:28:14	3534	502	2005-05-30 18:38:14	2	2006-02-15 21:30:53
259	2005-05-26 15:32:46	30	482	2005-06-04 15:27:46	2	2006-02-15 21:30:53
260	2005-05-26 15:42:20	435	21	2005-05-31 13:21:20	2	2006-02-15 21:30:53
261	2005-05-26 15:44:23	1369	414	2005-06-02 09:47:23	2	2006-02-15 21:30:53
262	2005-05-26 15:46:56	4261	236	2005-05-28 15:49:56	2	2006-02-15 21:30:53
263	2005-05-26 15:47:40	1160	449	2005-05-30 10:07:40	2	2006-02-15 21:30:53
264	2005-05-26 16:00:49	2069	251	2005-05-27 10:12:49	2	2006-02-15 21:30:53
265	2005-05-26 16:07:38	2276	303	2005-06-01 14:20:38	1	2006-02-15 21:30:53
266	2005-05-26 16:08:05	3303	263	2005-05-27 10:55:05	2	2006-02-15 21:30:53
267	2005-05-26 16:16:21	1206	417	2005-05-30 16:53:21	2	2006-02-15 21:30:53
268	2005-05-26 16:19:08	1714	75	2005-05-27 14:35:08	1	2006-02-15 21:30:53
269	2005-05-26 16:19:46	3501	322	2005-05-27 15:59:46	2	2006-02-15 21:30:53
270	2005-05-26 16:20:56	207	200	2005-06-03 12:40:56	2	2006-02-15 21:30:53
271	2005-05-26 16:22:01	2388	92	2005-06-03 17:30:01	2	2006-02-15 21:30:53
272	2005-05-26 16:27:11	971	71	2005-06-03 13:10:11	2	2006-02-15 21:30:53
273	2005-05-26 16:29:36	1590	193	2005-05-29 18:49:36	2	2006-02-15 21:30:53
274	2005-05-26 16:48:51	656	311	2005-06-03 18:17:51	1	2006-02-15 21:30:53
275	2005-05-26 17:09:53	1718	133	2005-06-04 22:35:53	1	2006-02-15 21:30:53
276	2005-05-26 17:16:07	1221	58	2005-06-03 12:59:07	1	2006-02-15 21:30:53
277	2005-05-26 17:32:11	1409	45	2005-05-28 22:54:11	1	2006-02-15 21:30:53
278	2005-05-26 17:40:58	182	214	2005-06-02 16:43:58	2	2006-02-15 21:30:53
279	2005-05-26 18:02:50	661	384	2005-06-03 18:48:50	2	2006-02-15 21:30:53
280	2005-05-26 18:36:58	1896	167	2005-05-27 23:42:58	1	2006-02-15 21:30:53
281	2005-05-26 18:49:35	1208	582	2005-05-27 18:11:35	2	2006-02-15 21:30:53
282	2005-05-26 18:56:26	4486	282	2005-06-01 16:32:26	2	2006-02-15 21:30:53
283	2005-05-26 19:05:05	3530	242	2005-05-31 19:19:05	1	2006-02-15 21:30:53
284	2005-05-26 19:21:44	350	359	2005-06-04 14:18:44	2	2006-02-15 21:30:53
285	2005-05-26 19:41:40	2486	162	2005-05-31 16:58:40	2	2006-02-15 21:30:53
286	2005-05-26 19:44:51	314	371	2005-06-04 18:00:51	2	2006-02-15 21:30:53
287	2005-05-26 19:44:54	3631	17	2005-06-02 01:10:54	1	2006-02-15 21:30:53
288	2005-05-26 19:47:49	3546	82	2005-06-03 20:53:49	2	2006-02-15 21:30:53
289	2005-05-26 20:01:09	2449	81	2005-05-28 15:09:09	1	2006-02-15 21:30:53
290	2005-05-26 20:08:33	2776	429	2005-05-30 00:32:33	1	2006-02-15 21:30:53
291	2005-05-26 20:20:47	485	577	2005-06-03 02:06:47	2	2006-02-15 21:30:53
292	2005-05-26 20:22:12	4264	515	2005-06-05 00:58:12	1	2006-02-15 21:30:53
293	2005-05-26 20:27:02	1828	158	2005-06-03 16:45:02	2	2006-02-15 21:30:53
294	2005-05-26 20:29:57	2751	369	2005-05-28 17:20:57	1	2006-02-15 21:30:53
295	2005-05-26 20:33:20	4030	65	2005-05-27 18:23:20	2	2006-02-15 21:30:53
296	2005-05-26 20:35:19	3878	468	2005-06-04 02:31:19	2	2006-02-15 21:30:53
297	2005-05-26 20:48:48	1594	48	2005-05-27 19:52:48	2	2006-02-15 21:30:53
298	2005-05-26 20:52:26	1083	460	2005-05-29 22:08:26	2	2006-02-15 21:30:53
299	2005-05-26 20:55:36	4376	448	2005-05-28 00:25:36	2	2006-02-15 21:30:53
300	2005-05-26 20:57:00	249	47	2005-06-05 01:34:00	2	2006-02-15 21:30:53
301	2005-05-26 21:06:14	3448	274	2005-06-01 01:54:14	2	2006-02-15 21:30:53
302	2005-05-26 21:13:46	2921	387	2005-06-03 15:49:46	2	2006-02-15 21:30:53
303	2005-05-26 21:16:52	1111	596	2005-05-27 23:41:52	2	2006-02-15 21:30:53
304	2005-05-26 21:21:28	1701	534	2005-06-02 00:05:28	1	2006-02-15 21:30:53
305	2005-05-26 21:22:07	2665	464	2005-06-02 22:33:07	2	2006-02-15 21:30:53
306	2005-05-26 21:31:57	2781	547	2005-05-28 19:37:57	1	2006-02-15 21:30:53
307	2005-05-26 21:48:13	1097	375	2005-06-04 22:24:13	1	2006-02-15 21:30:53
308	2005-05-26 22:01:39	187	277	2005-06-04 20:24:39	2	2006-02-15 21:30:53
309	2005-05-26 22:38:10	1946	251	2005-06-02 03:10:10	2	2006-02-15 21:30:53
310	2005-05-26 22:41:07	593	409	2005-06-02 04:09:07	1	2006-02-15 21:30:53
311	2005-05-26 22:51:37	2830	201	2005-06-01 00:02:37	1	2006-02-15 21:30:53
312	2005-05-26 22:52:19	2008	143	2005-06-02 18:14:19	2	2006-02-15 21:30:53
313	2005-05-26 22:56:19	4156	594	2005-05-29 01:29:19	2	2006-02-15 21:30:53
314	2005-05-26 23:09:41	2851	203	2005-05-28 22:49:41	2	2006-02-15 21:30:53
315	2005-05-26 23:12:55	2847	238	2005-05-29 23:33:55	1	2006-02-15 21:30:53
316	2005-05-26 23:22:55	3828	249	2005-05-29 23:25:55	2	2006-02-15 21:30:53
317	2005-05-26 23:23:56	26	391	2005-06-01 19:56:56	2	2006-02-15 21:30:53
318	2005-05-26 23:37:39	2559	60	2005-06-03 04:31:39	2	2006-02-15 21:30:53
319	2005-05-26 23:52:13	3024	77	2005-05-30 18:55:13	1	2006-02-15 21:30:53
320	2005-05-27 00:09:24	1090	2	2005-05-28 04:30:24	2	2006-02-15 21:30:53
322	2005-05-27 00:47:35	4556	496	2005-06-02 00:32:35	1	2006-02-15 21:30:53
323	2005-05-27 00:49:27	2362	144	2005-05-30 03:12:27	1	2006-02-15 21:30:53
324	2005-05-27 01:00:04	3364	292	2005-05-30 04:27:04	1	2006-02-15 21:30:53
325	2005-05-27 01:09:55	2510	449	2005-05-31 07:01:55	2	2006-02-15 21:30:53
326	2005-05-27 01:10:11	3979	432	2005-06-04 20:25:11	2	2006-02-15 21:30:53
327	2005-05-27 01:18:57	2678	105	2005-06-04 04:06:57	1	2006-02-15 21:30:53
328	2005-05-27 01:29:31	2524	451	2005-06-01 02:27:31	1	2006-02-15 21:30:53
329	2005-05-27 01:57:14	2659	231	2005-05-31 04:19:14	2	2006-02-15 21:30:53
330	2005-05-27 02:15:30	1536	248	2005-06-04 05:09:30	2	2006-02-15 21:30:53
331	2005-05-27 02:22:26	1872	67	2005-06-05 00:25:26	1	2006-02-15 21:30:53
332	2005-05-27 02:27:10	1529	299	2005-06-03 01:26:10	2	2006-02-15 21:30:53
333	2005-05-27 02:52:21	4001	412	2005-06-01 00:55:21	2	2006-02-15 21:30:53
334	2005-05-27 03:03:07	3973	194	2005-05-29 03:54:07	1	2006-02-15 21:30:53
335	2005-05-27 03:07:10	1411	16	2005-06-05 00:15:10	2	2006-02-15 21:30:53
336	2005-05-27 03:15:23	1811	275	2005-05-29 22:43:23	1	2006-02-15 21:30:53
337	2005-05-27 03:22:30	751	19	2005-06-02 03:27:30	1	2006-02-15 21:30:53
338	2005-05-27 03:42:52	2596	165	2005-06-01 05:23:52	2	2006-02-15 21:30:53
339	2005-05-27 03:47:18	2410	516	2005-06-04 05:46:18	2	2006-02-15 21:30:53
340	2005-05-27 03:55:25	946	209	2005-06-04 07:57:25	2	2006-02-15 21:30:53
341	2005-05-27 04:01:42	4168	56	2005-06-05 08:51:42	1	2006-02-15 21:30:53
342	2005-05-27 04:11:04	4019	539	2005-05-29 01:28:04	2	2006-02-15 21:30:53
343	2005-05-27 04:13:41	3301	455	2005-05-28 08:34:41	1	2006-02-15 21:30:53
344	2005-05-27 04:30:22	2327	236	2005-05-29 10:13:22	2	2006-02-15 21:30:53
345	2005-05-27 04:32:25	1396	144	2005-05-31 09:50:25	1	2006-02-15 21:30:53
346	2005-05-27 04:34:41	4319	14	2005-06-05 04:24:41	2	2006-02-15 21:30:53
347	2005-05-27 04:40:33	1625	378	2005-05-28 09:56:33	2	2006-02-15 21:30:53
348	2005-05-27 04:50:56	1825	473	2005-06-01 04:43:56	1	2006-02-15 21:30:53
349	2005-05-27 04:53:11	2920	36	2005-05-28 06:33:11	2	2006-02-15 21:30:53
350	2005-05-27 05:01:28	2756	9	2005-06-04 05:01:28	2	2006-02-15 21:30:53
351	2005-05-27 05:39:03	3371	118	2005-06-01 11:10:03	1	2006-02-15 21:30:53
352	2005-05-27 05:48:19	4369	157	2005-05-29 09:05:19	1	2006-02-15 21:30:53
353	2005-05-27 06:03:39	3989	503	2005-06-03 04:39:39	2	2006-02-15 21:30:53
354	2005-05-27 06:12:26	2058	452	2005-06-01 06:48:26	1	2006-02-15 21:30:53
355	2005-05-27 06:15:33	141	446	2005-06-01 02:50:33	2	2006-02-15 21:30:53
356	2005-05-27 06:32:30	2868	382	2005-05-30 06:24:30	2	2006-02-15 21:30:53
357	2005-05-27 06:37:15	4417	198	2005-05-30 07:04:15	2	2006-02-15 21:30:53
358	2005-05-27 06:43:59	1925	102	2005-05-29 11:28:59	2	2006-02-15 21:30:53
359	2005-05-27 06:48:33	1156	152	2005-05-29 03:55:33	1	2006-02-15 21:30:53
360	2005-05-27 06:51:14	3489	594	2005-06-03 01:58:14	1	2006-02-15 21:30:53
361	2005-05-27 07:03:28	6	587	2005-05-31 08:01:28	1	2006-02-15 21:30:53
362	2005-05-27 07:10:25	2324	147	2005-06-01 08:34:25	1	2006-02-15 21:30:53
363	2005-05-27 07:14:00	4282	345	2005-05-28 12:22:00	2	2006-02-15 21:30:53
364	2005-05-27 07:20:12	833	430	2005-05-31 10:44:12	2	2006-02-15 21:30:53
365	2005-05-27 07:31:20	2887	167	2005-06-04 04:46:20	1	2006-02-15 21:30:53
366	2005-05-27 07:33:54	360	134	2005-06-04 01:55:54	2	2006-02-15 21:30:53
367	2005-05-27 07:37:02	3437	439	2005-05-30 05:43:02	2	2006-02-15 21:30:53
368	2005-05-27 07:42:29	1247	361	2005-06-04 11:20:29	2	2006-02-15 21:30:53
369	2005-05-27 07:46:49	944	508	2005-06-01 06:20:49	2	2006-02-15 21:30:53
370	2005-05-27 07:49:43	3347	22	2005-06-05 06:39:43	2	2006-02-15 21:30:53
371	2005-05-27 08:08:18	1235	295	2005-06-05 03:05:18	2	2006-02-15 21:30:53
372	2005-05-27 08:13:58	4089	510	2005-06-04 03:50:58	2	2006-02-15 21:30:53
373	2005-05-27 08:16:25	1649	464	2005-06-01 11:41:25	1	2006-02-15 21:30:53
374	2005-05-27 08:26:30	4420	337	2005-06-05 07:13:30	1	2006-02-15 21:30:53
375	2005-05-27 08:49:21	1815	306	2005-06-04 14:11:21	1	2006-02-15 21:30:53
376	2005-05-27 08:58:15	3197	542	2005-06-02 04:48:15	1	2006-02-15 21:30:53
377	2005-05-27 09:04:05	3012	170	2005-06-02 03:36:05	2	2006-02-15 21:30:53
378	2005-05-27 09:23:22	2242	53	2005-05-29 15:20:22	1	2006-02-15 21:30:53
379	2005-05-27 09:25:32	3462	584	2005-06-02 06:19:32	1	2006-02-15 21:30:53
380	2005-05-27 09:34:39	1777	176	2005-06-04 11:45:39	1	2006-02-15 21:30:53
381	2005-05-27 09:43:25	2748	371	2005-05-31 12:00:25	1	2006-02-15 21:30:53
382	2005-05-27 10:12:00	4358	183	2005-05-31 15:03:00	1	2006-02-15 21:30:53
383	2005-05-27 10:12:20	955	298	2005-06-03 10:37:20	1	2006-02-15 21:30:53
384	2005-05-27 10:18:20	910	371	2005-06-02 09:21:20	2	2006-02-15 21:30:53
385	2005-05-27 10:23:25	1565	213	2005-05-30 15:27:25	2	2006-02-15 21:30:53
386	2005-05-27 10:26:31	1288	109	2005-05-30 08:32:31	1	2006-02-15 21:30:53
387	2005-05-27 10:35:27	2684	506	2005-06-01 13:37:27	2	2006-02-15 21:30:53
388	2005-05-27 10:37:27	434	28	2005-05-30 05:45:27	1	2006-02-15 21:30:53
389	2005-05-27 10:45:41	691	500	2005-06-05 06:22:41	2	2006-02-15 21:30:53
390	2005-05-27 11:02:26	3759	48	2005-06-02 16:09:26	2	2006-02-15 21:30:53
391	2005-05-27 11:03:55	2193	197	2005-06-01 11:59:55	2	2006-02-15 21:30:53
392	2005-05-27 11:14:42	263	359	2005-06-01 14:28:42	2	2006-02-15 21:30:53
393	2005-05-27 11:18:25	145	251	2005-05-28 07:10:25	2	2006-02-15 21:30:53
394	2005-05-27 11:26:11	1890	274	2005-06-03 16:44:11	2	2006-02-15 21:30:53
395	2005-05-27 11:45:49	752	575	2005-05-31 13:42:49	1	2006-02-15 21:30:53
396	2005-05-27 11:47:04	1020	112	2005-05-29 10:14:04	1	2006-02-15 21:30:53
397	2005-05-27 12:29:02	4193	544	2005-05-28 17:36:02	2	2006-02-15 21:30:53
398	2005-05-27 12:44:03	1686	422	2005-06-02 08:19:03	1	2006-02-15 21:30:53
399	2005-05-27 12:48:38	553	204	2005-05-29 15:27:38	1	2006-02-15 21:30:53
400	2005-05-27 12:51:44	258	249	2005-05-31 08:34:44	2	2006-02-15 21:30:53
401	2005-05-27 12:57:55	2179	46	2005-05-29 17:55:55	2	2006-02-15 21:30:53
402	2005-05-27 13:17:18	461	354	2005-05-30 08:53:18	2	2006-02-15 21:30:53
403	2005-05-27 13:28:52	3983	424	2005-05-29 11:47:52	2	2006-02-15 21:30:53
404	2005-05-27 13:31:51	1293	168	2005-05-30 16:58:51	1	2006-02-15 21:30:53
405	2005-05-27 13:32:39	4090	272	2005-06-05 18:53:39	2	2006-02-15 21:30:53
406	2005-05-27 13:46:46	2136	381	2005-05-30 12:43:46	1	2006-02-15 21:30:53
407	2005-05-27 13:57:38	1077	44	2005-05-31 18:23:38	1	2006-02-15 21:30:53
408	2005-05-27 13:57:39	1438	84	2005-05-28 11:57:39	1	2006-02-15 21:30:53
409	2005-05-27 14:10:58	3652	220	2005-06-02 10:40:58	2	2006-02-15 21:30:53
410	2005-05-27 14:11:22	4010	506	2005-06-02 20:06:22	2	2006-02-15 21:30:53
411	2005-05-27 14:14:14	1434	388	2005-06-03 17:39:14	1	2006-02-15 21:30:53
412	2005-05-27 14:17:23	1400	375	2005-05-29 15:07:23	2	2006-02-15 21:30:53
413	2005-05-27 14:45:37	3516	307	2005-06-03 11:11:37	1	2006-02-15 21:30:53
414	2005-05-27 14:48:20	1019	219	2005-05-31 14:39:20	2	2006-02-15 21:30:53
415	2005-05-27 14:51:45	3698	304	2005-05-28 19:07:45	2	2006-02-15 21:30:53
416	2005-05-27 15:02:10	2371	222	2005-05-29 10:34:10	2	2006-02-15 21:30:53
417	2005-05-27 15:07:27	2253	475	2005-05-29 20:01:27	2	2006-02-15 21:30:53
418	2005-05-27 15:13:17	3063	151	2005-06-04 12:05:17	2	2006-02-15 21:30:53
419	2005-05-27 15:15:11	2514	77	2005-06-02 11:53:11	1	2006-02-15 21:30:53
420	2005-05-27 15:19:38	619	93	2005-06-03 15:07:38	2	2006-02-15 21:30:53
421	2005-05-27 15:30:13	2985	246	2005-06-04 13:19:13	2	2006-02-15 21:30:53
422	2005-05-27 15:31:55	1152	150	2005-06-01 11:47:55	2	2006-02-15 21:30:53
423	2005-05-27 15:32:57	1783	284	2005-06-02 19:03:57	1	2006-02-15 21:30:53
424	2005-05-27 15:34:01	2815	35	2005-06-05 09:44:01	1	2006-02-15 21:30:53
425	2005-05-27 15:51:30	1518	182	2005-06-03 16:52:30	2	2006-02-15 21:30:53
426	2005-05-27 15:56:57	1103	522	2005-06-05 11:45:57	1	2006-02-15 21:30:53
427	2005-05-27 16:10:04	1677	288	2005-06-05 13:22:04	2	2006-02-15 21:30:53
428	2005-05-27 16:10:58	3349	161	2005-05-31 17:24:58	2	2006-02-15 21:30:53
429	2005-05-27 16:21:26	129	498	2005-06-05 20:23:26	2	2006-02-15 21:30:53
430	2005-05-27 16:22:10	1920	190	2005-06-05 13:10:10	1	2006-02-15 21:30:53
431	2005-05-27 16:31:05	4507	334	2005-06-05 11:29:05	1	2006-02-15 21:30:53
432	2005-05-27 16:40:29	1119	46	2005-05-29 16:20:29	1	2006-02-15 21:30:53
433	2005-05-27 16:40:40	4364	574	2005-05-30 19:55:40	2	2006-02-15 21:30:53
434	2005-05-27 16:54:27	3360	246	2005-06-04 22:26:27	1	2006-02-15 21:30:53
435	2005-05-27 17:17:09	3328	3	2005-06-02 11:20:09	2	2006-02-15 21:30:53
436	2005-05-27 17:21:04	4317	267	2005-05-30 21:26:04	2	2006-02-15 21:30:53
437	2005-05-27 17:47:22	1800	525	2005-06-05 14:22:22	2	2006-02-15 21:30:53
438	2005-05-27 17:52:34	4260	249	2005-06-05 22:23:34	2	2006-02-15 21:30:53
439	2005-05-27 17:54:48	354	319	2005-06-02 23:01:48	2	2006-02-15 21:30:53
440	2005-05-27 18:00:35	4452	314	2005-05-29 16:15:35	1	2006-02-15 21:30:53
441	2005-05-27 18:11:05	1578	54	2005-05-30 22:45:05	1	2006-02-15 21:30:53
442	2005-05-27 18:12:13	1457	403	2005-05-30 12:30:13	2	2006-02-15 21:30:53
443	2005-05-27 18:35:20	2021	547	2005-06-04 18:58:20	1	2006-02-15 21:30:53
444	2005-05-27 18:39:15	723	239	2005-06-01 15:56:15	1	2006-02-15 21:30:53
445	2005-05-27 18:42:57	1757	293	2005-05-30 22:35:57	2	2006-02-15 21:30:53
446	2005-05-27 18:48:41	1955	401	2005-06-03 16:42:41	2	2006-02-15 21:30:53
447	2005-05-27 18:57:02	3890	133	2005-06-05 18:38:02	1	2006-02-15 21:30:53
448	2005-05-27 19:03:08	2671	247	2005-06-03 20:28:08	2	2006-02-15 21:30:53
449	2005-05-27 19:13:15	2469	172	2005-06-04 01:08:15	2	2006-02-15 21:30:53
450	2005-05-27 19:18:54	1343	247	2005-06-05 23:52:54	1	2006-02-15 21:30:53
451	2005-05-27 19:27:54	205	87	2005-05-29 01:07:54	2	2006-02-15 21:30:53
452	2005-05-27 19:30:33	2993	127	2005-05-30 20:53:33	2	2006-02-15 21:30:53
453	2005-05-27 19:31:16	4425	529	2005-05-29 23:06:16	1	2006-02-15 21:30:53
454	2005-05-27 19:31:36	3499	575	2005-05-30 15:46:36	1	2006-02-15 21:30:53
455	2005-05-27 19:43:29	3344	343	2005-06-04 23:40:29	2	2006-02-15 21:30:53
456	2005-05-27 19:50:06	1699	92	2005-06-02 22:14:06	1	2006-02-15 21:30:53
457	2005-05-27 19:52:29	2368	300	2005-06-02 17:17:29	2	2006-02-15 21:30:53
458	2005-05-27 19:58:36	3350	565	2005-06-06 00:51:36	1	2006-02-15 21:30:53
459	2005-05-27 20:00:04	597	468	2005-05-29 22:47:04	1	2006-02-15 21:30:53
460	2005-05-27 20:02:03	4238	240	2005-05-28 16:14:03	1	2006-02-15 21:30:53
461	2005-05-27 20:08:55	2077	447	2005-06-01 14:32:55	1	2006-02-15 21:30:53
462	2005-05-27 20:10:36	2314	364	2005-06-03 21:12:36	2	2006-02-15 21:30:53
463	2005-05-27 20:11:47	826	21	2005-06-04 21:18:47	1	2006-02-15 21:30:53
464	2005-05-27 20:42:44	1313	193	2005-05-30 00:49:44	2	2006-02-15 21:30:53
465	2005-05-27 20:44:36	20	261	2005-06-02 02:43:36	1	2006-02-15 21:30:53
466	2005-05-27 20:57:07	1786	442	2005-05-29 15:52:07	1	2006-02-15 21:30:53
467	2005-05-27 21:10:03	339	557	2005-06-01 16:08:03	1	2006-02-15 21:30:53
468	2005-05-27 21:13:10	2656	101	2005-06-04 15:26:10	2	2006-02-15 21:30:53
469	2005-05-27 21:14:26	4463	154	2005-06-05 21:51:26	1	2006-02-15 21:30:53
470	2005-05-27 21:17:08	1613	504	2005-06-04 17:47:08	1	2006-02-15 21:30:53
471	2005-05-27 21:32:42	2872	209	2005-05-31 00:39:42	2	2006-02-15 21:30:53
472	2005-05-27 21:36:15	1338	528	2005-05-29 21:07:15	1	2006-02-15 21:30:53
473	2005-05-27 21:36:34	802	105	2005-06-05 17:02:34	1	2006-02-15 21:30:53
474	2005-05-27 22:11:56	1474	274	2005-05-31 19:07:56	1	2006-02-15 21:30:53
475	2005-05-27 22:16:26	2520	159	2005-05-28 19:58:26	1	2006-02-15 21:30:53
476	2005-05-27 22:31:36	2451	543	2005-06-03 19:12:36	1	2006-02-15 21:30:53
477	2005-05-27 22:33:33	2437	161	2005-06-02 18:35:33	2	2006-02-15 21:30:53
478	2005-05-27 22:38:20	424	557	2005-05-31 18:39:20	2	2006-02-15 21:30:53
479	2005-05-27 22:39:10	2060	231	2005-06-05 22:46:10	2	2006-02-15 21:30:53
480	2005-05-27 22:47:39	2108	220	2005-06-04 21:17:39	2	2006-02-15 21:30:53
481	2005-05-27 22:49:27	72	445	2005-05-30 17:46:27	2	2006-02-15 21:30:53
482	2005-05-27 22:53:02	4178	546	2005-06-01 22:53:02	2	2006-02-15 21:30:53
483	2005-05-27 23:00:25	1510	32	2005-05-28 21:30:25	1	2006-02-15 21:30:53
484	2005-05-27 23:26:45	3115	491	2005-05-29 21:16:45	2	2006-02-15 21:30:53
485	2005-05-27 23:40:52	2392	105	2005-05-28 22:40:52	2	2006-02-15 21:30:53
486	2005-05-27 23:51:12	1822	398	2005-05-28 20:26:12	1	2006-02-15 21:30:53
487	2005-05-28 00:00:30	3774	569	2005-05-28 19:18:30	2	2006-02-15 21:30:53
488	2005-05-28 00:07:50	393	168	2005-06-03 22:30:50	2	2006-02-15 21:30:53
489	2005-05-28 00:09:12	1940	476	2005-05-31 04:44:12	2	2006-02-15 21:30:53
490	2005-05-28 00:09:56	3524	95	2005-05-30 22:32:56	2	2006-02-15 21:30:53
491	2005-05-28 00:13:35	1326	196	2005-05-29 00:11:35	2	2006-02-15 21:30:53
492	2005-05-28 00:24:58	1999	228	2005-05-28 22:34:58	1	2006-02-15 21:30:53
493	2005-05-28 00:34:11	184	501	2005-05-30 18:40:11	1	2006-02-15 21:30:53
494	2005-05-28 00:39:31	1850	64	2005-06-02 19:35:31	1	2006-02-15 21:30:53
495	2005-05-28 00:40:48	1007	526	2005-05-29 06:07:48	1	2006-02-15 21:30:53
496	2005-05-28 00:43:41	1785	56	2005-06-04 03:56:41	1	2006-02-15 21:30:53
497	2005-05-28 00:54:39	2636	20	2005-06-03 20:47:39	2	2006-02-15 21:30:53
498	2005-05-28 01:01:21	458	287	2005-05-30 21:20:21	2	2006-02-15 21:30:53
499	2005-05-28 01:05:07	2381	199	2005-06-05 19:54:07	2	2006-02-15 21:30:53
500	2005-05-28 01:05:25	4500	145	2005-05-31 20:04:25	1	2006-02-15 21:30:53
501	2005-05-28 01:09:36	601	162	2005-05-30 06:14:36	2	2006-02-15 21:30:53
502	2005-05-28 01:34:43	3131	179	2005-05-31 01:02:43	2	2006-02-15 21:30:53
503	2005-05-28 01:35:25	3005	288	2005-05-28 22:12:25	2	2006-02-15 21:30:53
504	2005-05-28 02:05:34	2086	170	2005-05-30 23:03:34	1	2006-02-15 21:30:53
505	2005-05-28 02:06:37	71	111	2005-05-29 06:57:37	1	2006-02-15 21:30:53
506	2005-05-28 02:09:19	667	469	2005-06-05 20:34:19	1	2006-02-15 21:30:53
507	2005-05-28 02:31:19	3621	421	2005-06-02 05:07:19	2	2006-02-15 21:30:53
508	2005-05-28 02:40:50	4179	434	2005-06-05 03:05:50	1	2006-02-15 21:30:53
509	2005-05-28 02:51:12	3416	147	2005-05-31 06:27:12	1	2006-02-15 21:30:53
510	2005-05-28 02:52:14	4338	113	2005-05-30 21:20:14	2	2006-02-15 21:30:53
511	2005-05-28 03:04:04	3827	296	2005-06-03 04:58:04	1	2006-02-15 21:30:53
512	2005-05-28 03:07:50	2176	231	2005-06-05 02:12:50	2	2006-02-15 21:30:53
513	2005-05-28 03:08:10	225	489	2005-05-29 07:22:10	1	2006-02-15 21:30:53
514	2005-05-28 03:09:28	1697	597	2005-06-05 00:49:28	2	2006-02-15 21:30:53
515	2005-05-28 03:10:10	3369	110	2005-06-04 02:18:10	2	2006-02-15 21:30:53
516	2005-05-28 03:11:47	4357	400	2005-06-04 02:19:47	1	2006-02-15 21:30:53
517	2005-05-28 03:17:57	234	403	2005-05-29 06:33:57	1	2006-02-15 21:30:53
518	2005-05-28 03:18:02	4087	480	2005-05-30 05:32:02	1	2006-02-15 21:30:53
519	2005-05-28 03:22:33	3564	245	2005-06-03 05:06:33	1	2006-02-15 21:30:53
520	2005-05-28 03:27:37	3845	161	2005-06-04 05:47:37	1	2006-02-15 21:30:53
521	2005-05-28 03:32:22	2397	374	2005-05-28 22:37:22	1	2006-02-15 21:30:53
522	2005-05-28 03:33:20	3195	382	2005-05-31 04:23:20	1	2006-02-15 21:30:53
523	2005-05-28 03:53:26	1905	138	2005-05-31 05:58:26	2	2006-02-15 21:30:53
524	2005-05-28 03:57:28	1962	223	2005-05-31 05:20:28	1	2006-02-15 21:30:53
525	2005-05-28 04:25:33	1817	14	2005-06-06 04:18:33	1	2006-02-15 21:30:53
526	2005-05-28 04:27:37	1387	408	2005-05-30 07:52:37	1	2006-02-15 21:30:53
527	2005-05-28 04:28:38	266	169	2005-06-02 08:19:38	1	2006-02-15 21:30:53
528	2005-05-28 04:30:05	1655	359	2005-06-03 10:01:05	2	2006-02-15 21:30:53
529	2005-05-28 04:34:17	2624	469	2005-05-30 00:35:17	1	2006-02-15 21:30:53
530	2005-05-28 05:13:01	3332	312	2005-06-01 10:21:01	2	2006-02-15 21:30:53
531	2005-05-28 05:23:38	1113	589	2005-05-29 08:00:38	2	2006-02-15 21:30:53
532	2005-05-28 05:36:58	2793	120	2005-06-02 01:50:58	1	2006-02-15 21:30:53
533	2005-05-28 06:14:46	4306	528	2005-06-01 06:26:46	2	2006-02-15 21:30:53
534	2005-05-28 06:15:25	992	184	2005-06-06 07:51:25	1	2006-02-15 21:30:53
535	2005-05-28 06:16:32	4209	307	2005-05-31 02:48:32	1	2006-02-15 21:30:53
536	2005-05-28 06:17:33	2962	514	2005-06-03 10:02:33	2	2006-02-15 21:30:53
537	2005-05-28 06:20:55	3095	315	2005-06-05 11:48:55	2	2006-02-15 21:30:53
538	2005-05-28 06:21:05	2262	110	2005-06-02 01:22:05	2	2006-02-15 21:30:53
539	2005-05-28 06:26:16	3427	161	2005-05-30 02:02:16	1	2006-02-15 21:30:53
540	2005-05-28 06:40:25	3321	119	2005-06-06 00:47:25	1	2006-02-15 21:30:53
541	2005-05-28 06:41:58	1662	535	2005-06-02 09:12:58	2	2006-02-15 21:30:53
542	2005-05-28 06:42:13	4444	261	2005-06-03 09:05:13	1	2006-02-15 21:30:53
543	2005-05-28 06:43:34	530	493	2005-06-06 07:16:34	2	2006-02-15 21:30:53
544	2005-05-28 07:03:00	2964	311	2005-06-06 06:23:00	1	2006-02-15 21:30:53
545	2005-05-28 07:10:20	1086	54	2005-06-04 01:47:20	2	2006-02-15 21:30:53
546	2005-05-28 07:16:25	487	20	2005-06-01 08:36:25	1	2006-02-15 21:30:53
547	2005-05-28 07:24:28	2065	506	2005-06-06 01:31:28	2	2006-02-15 21:30:53
548	2005-05-28 07:34:56	3704	450	2005-06-05 03:14:56	2	2006-02-15 21:30:53
549	2005-05-28 07:35:37	1818	159	2005-06-02 09:08:37	1	2006-02-15 21:30:53
550	2005-05-28 07:39:16	3632	432	2005-06-06 12:20:16	2	2006-02-15 21:30:53
551	2005-05-28 07:44:18	3119	315	2005-06-02 12:55:18	2	2006-02-15 21:30:53
552	2005-05-28 07:53:38	23	106	2005-06-04 12:45:38	2	2006-02-15 21:30:53
553	2005-05-28 08:14:44	1349	176	2005-06-02 03:01:44	2	2006-02-15 21:30:53
554	2005-05-28 08:23:16	1951	376	2005-05-31 03:29:16	2	2006-02-15 21:30:53
555	2005-05-28 08:31:14	4397	55	2005-05-30 07:34:14	2	2006-02-15 21:30:53
556	2005-05-28 08:31:36	1814	22	2005-06-06 07:29:36	2	2006-02-15 21:30:53
557	2005-05-28 08:36:22	158	444	2005-06-03 10:42:22	2	2006-02-15 21:30:53
558	2005-05-28 08:38:43	4163	442	2005-06-06 13:52:43	1	2006-02-15 21:30:53
559	2005-05-28 08:39:02	1227	572	2005-06-05 08:38:02	2	2006-02-15 21:30:53
560	2005-05-28 08:53:02	644	463	2005-06-04 12:27:02	2	2006-02-15 21:30:53
561	2005-05-28 08:54:06	928	77	2005-06-05 05:54:06	1	2006-02-15 21:30:53
562	2005-05-28 09:01:21	3390	102	2005-06-02 05:26:21	2	2006-02-15 21:30:53
563	2005-05-28 09:10:49	53	324	2005-06-06 11:32:49	1	2006-02-15 21:30:53
564	2005-05-28 09:12:09	2973	282	2005-05-29 05:07:09	1	2006-02-15 21:30:53
565	2005-05-28 09:26:31	1494	288	2005-06-01 07:28:31	1	2006-02-15 21:30:53
566	2005-05-28 09:51:39	4330	253	2005-06-05 09:35:39	1	2006-02-15 21:30:53
567	2005-05-28 09:56:20	3308	184	2005-06-01 06:41:20	2	2006-02-15 21:30:53
568	2005-05-28 09:57:36	2232	155	2005-05-31 15:44:36	1	2006-02-15 21:30:53
569	2005-05-28 10:12:41	4534	56	2005-06-03 10:08:41	2	2006-02-15 21:30:53
570	2005-05-28 10:15:04	1122	21	2005-05-30 08:32:04	1	2006-02-15 21:30:53
571	2005-05-28 10:17:41	4250	516	2005-06-05 07:56:41	1	2006-02-15 21:30:53
572	2005-05-28 10:30:13	1899	337	2005-06-02 05:04:13	2	2006-02-15 21:30:53
573	2005-05-28 10:35:23	4020	1	2005-06-03 06:32:23	1	2006-02-15 21:30:53
574	2005-05-28 10:44:28	3883	76	2005-06-04 11:42:28	1	2006-02-15 21:30:53
575	2005-05-28 10:56:09	4451	142	2005-06-05 15:39:09	1	2006-02-15 21:30:53
576	2005-05-28 10:56:10	1866	588	2005-06-04 13:15:10	2	2006-02-15 21:30:53
577	2005-05-28 11:09:14	375	6	2005-06-01 13:27:14	2	2006-02-15 21:30:53
578	2005-05-28 11:15:48	2938	173	2005-06-02 09:59:48	1	2006-02-15 21:30:53
579	2005-05-28 11:19:23	3481	181	2005-06-02 13:51:23	1	2006-02-15 21:30:53
580	2005-05-28 11:19:53	3515	17	2005-06-01 10:44:53	2	2006-02-15 21:30:53
581	2005-05-28 11:20:29	1380	186	2005-06-04 12:37:29	2	2006-02-15 21:30:53
582	2005-05-28 11:33:46	4579	198	2005-05-29 08:33:46	1	2006-02-15 21:30:53
583	2005-05-28 11:48:55	2679	386	2005-06-04 07:09:55	2	2006-02-15 21:30:53
584	2005-05-28 11:49:00	1833	69	2005-06-01 11:54:00	1	2006-02-15 21:30:53
585	2005-05-28 11:50:45	3544	490	2005-06-03 15:35:45	2	2006-02-15 21:30:53
586	2005-05-28 12:03:00	898	77	2005-05-29 13:16:00	1	2006-02-15 21:30:53
587	2005-05-28 12:05:33	1413	64	2005-05-30 13:45:33	2	2006-02-15 21:30:53
588	2005-05-28 12:08:37	95	89	2005-05-29 16:25:37	2	2006-02-15 21:30:53
589	2005-05-28 12:27:50	4231	308	2005-06-03 07:15:50	2	2006-02-15 21:30:53
590	2005-05-28 13:06:50	473	462	2005-06-02 09:18:50	1	2006-02-15 21:30:53
591	2005-05-28 13:11:04	377	19	2005-05-29 17:20:04	2	2006-02-15 21:30:53
592	2005-05-28 13:21:08	638	244	2005-05-29 16:55:08	1	2006-02-15 21:30:53
593	2005-05-28 13:33:23	1810	16	2005-05-30 17:10:23	2	2006-02-15 21:30:53
594	2005-05-28 13:41:56	2766	538	2005-05-30 12:00:56	1	2006-02-15 21:30:53
595	2005-05-28 13:59:54	595	294	2005-06-05 15:16:54	1	2006-02-15 21:30:53
596	2005-05-28 14:00:03	821	589	2005-05-29 17:10:03	1	2006-02-15 21:30:53
597	2005-05-28 14:01:02	4469	249	2005-06-06 19:06:02	2	2006-02-15 21:30:53
598	2005-05-28 14:04:50	599	159	2005-06-03 18:00:50	2	2006-02-15 21:30:53
599	2005-05-28 14:05:57	4136	393	2005-06-01 16:41:57	2	2006-02-15 21:30:53
600	2005-05-28 14:08:19	1567	332	2005-06-03 11:57:19	2	2006-02-15 21:30:53
601	2005-05-28 14:08:22	3225	429	2005-06-04 10:50:22	1	2006-02-15 21:30:53
602	2005-05-28 14:15:54	1300	590	2005-06-05 15:16:54	2	2006-02-15 21:30:53
603	2005-05-28 14:27:51	3248	537	2005-05-29 13:13:51	1	2006-02-15 21:30:53
604	2005-05-28 14:37:07	1585	426	2005-06-03 11:03:07	2	2006-02-15 21:30:53
605	2005-05-28 14:39:10	4232	501	2005-06-01 09:28:10	2	2006-02-15 21:30:53
606	2005-05-28 14:48:39	3509	299	2005-06-04 09:44:39	2	2006-02-15 21:30:53
607	2005-05-28 15:02:41	2561	554	2005-05-30 12:54:41	2	2006-02-15 21:30:53
608	2005-05-28 15:03:44	4254	494	2005-06-04 17:14:44	2	2006-02-15 21:30:53
609	2005-05-28 15:04:02	2944	150	2005-06-05 14:47:02	2	2006-02-15 21:30:53
610	2005-05-28 15:15:25	3642	500	2005-06-02 12:30:25	2	2006-02-15 21:30:53
611	2005-05-28 15:18:18	1230	580	2005-05-31 20:15:18	2	2006-02-15 21:30:53
612	2005-05-28 15:24:54	2180	161	2005-05-30 14:22:54	2	2006-02-15 21:30:53
613	2005-05-28 15:27:22	270	595	2005-06-02 20:01:22	1	2006-02-15 21:30:53
614	2005-05-28 15:33:28	280	307	2005-06-04 12:27:28	2	2006-02-15 21:30:53
615	2005-05-28 15:35:52	3397	533	2005-06-03 17:35:52	2	2006-02-15 21:30:53
616	2005-05-28 15:45:39	989	471	2005-06-02 09:55:39	1	2006-02-15 21:30:53
617	2005-05-28 15:49:14	4142	372	2005-05-31 14:29:14	2	2006-02-15 21:30:53
618	2005-05-28 15:50:07	4445	248	2005-06-01 19:45:07	1	2006-02-15 21:30:53
619	2005-05-28 15:52:26	2482	407	2005-06-06 17:55:26	2	2006-02-15 21:30:53
620	2005-05-28 15:54:45	2444	321	2005-06-04 20:26:45	1	2006-02-15 21:30:53
621	2005-05-28 15:58:12	1144	239	2005-05-30 21:54:12	1	2006-02-15 21:30:53
622	2005-05-28 15:58:22	2363	109	2005-06-04 10:13:22	1	2006-02-15 21:30:53
623	2005-05-28 16:01:28	1222	495	2005-05-30 11:19:28	1	2006-02-15 21:30:53
624	2005-05-28 16:13:22	3660	569	2005-06-06 20:35:22	1	2006-02-15 21:30:53
625	2005-05-28 16:35:46	2889	596	2005-06-01 14:19:46	1	2006-02-15 21:30:53
626	2005-05-28 16:58:09	452	584	2005-06-01 14:02:09	2	2006-02-15 21:30:53
627	2005-05-28 17:04:43	425	241	2005-06-04 19:58:43	2	2006-02-15 21:30:53
628	2005-05-28 17:05:46	2513	173	2005-06-06 16:29:46	2	2006-02-15 21:30:53
629	2005-05-28 17:19:15	1527	94	2005-06-02 20:01:15	2	2006-02-15 21:30:53
630	2005-05-28 17:24:51	1254	417	2005-06-05 20:05:51	2	2006-02-15 21:30:53
631	2005-05-28 17:36:32	2465	503	2005-06-03 14:56:32	2	2006-02-15 21:30:53
632	2005-05-28 17:37:50	1287	442	2005-06-03 16:04:50	1	2006-02-15 21:30:53
633	2005-05-28 17:37:59	58	360	2005-06-03 22:49:59	2	2006-02-15 21:30:53
634	2005-05-28 17:40:35	2630	428	2005-06-05 16:18:35	2	2006-02-15 21:30:53
635	2005-05-28 17:46:57	1648	42	2005-06-06 18:24:57	1	2006-02-15 21:30:53
636	2005-05-28 17:47:58	4213	239	2005-06-04 16:32:58	1	2006-02-15 21:30:53
637	2005-05-28 18:14:29	1581	250	2005-05-29 23:48:29	2	2006-02-15 21:30:53
638	2005-05-28 18:24:43	2685	372	2005-06-02 19:03:43	2	2006-02-15 21:30:53
639	2005-05-28 18:25:02	4204	198	2005-05-29 18:22:02	1	2006-02-15 21:30:53
640	2005-05-28 18:43:26	495	465	2005-05-30 13:39:26	1	2006-02-15 21:30:53
641	2005-05-28 18:45:47	3548	396	2005-06-04 15:24:47	1	2006-02-15 21:30:53
642	2005-05-28 18:49:12	140	157	2005-06-01 20:50:12	2	2006-02-15 21:30:53
643	2005-05-28 18:52:11	3105	240	2005-05-31 15:15:11	2	2006-02-15 21:30:53
644	2005-05-28 18:59:12	4304	316	2005-06-04 18:06:12	1	2006-02-15 21:30:53
645	2005-05-28 19:14:09	3128	505	2005-06-05 14:01:09	1	2006-02-15 21:30:53
646	2005-05-28 19:16:14	1922	185	2005-05-31 16:50:14	2	2006-02-15 21:30:53
647	2005-05-28 19:22:52	3435	569	2005-06-01 00:10:52	1	2006-02-15 21:30:53
648	2005-05-28 19:25:54	3476	253	2005-06-03 15:57:54	2	2006-02-15 21:30:53
649	2005-05-28 19:35:45	1781	197	2005-06-05 16:00:45	1	2006-02-15 21:30:53
650	2005-05-28 19:45:40	4384	281	2005-05-29 21:02:40	1	2006-02-15 21:30:53
651	2005-05-28 19:46:50	739	266	2005-05-30 16:29:50	1	2006-02-15 21:30:53
652	2005-05-28 20:08:47	1201	43	2005-05-29 14:57:47	2	2006-02-15 21:30:53
653	2005-05-28 20:12:20	126	327	2005-06-04 14:44:20	2	2006-02-15 21:30:53
654	2005-05-28 20:15:30	2312	23	2005-05-30 22:02:30	2	2006-02-15 21:30:53
655	2005-05-28 20:16:20	331	287	2005-05-31 16:46:20	2	2006-02-15 21:30:53
656	2005-05-28 20:18:24	2846	437	2005-05-30 16:19:24	1	2006-02-15 21:30:53
657	2005-05-28 20:23:09	848	65	2005-06-01 02:11:09	1	2006-02-15 21:30:53
658	2005-05-28 20:23:23	3226	103	2005-06-06 19:31:23	2	2006-02-15 21:30:53
659	2005-05-28 20:27:53	1382	207	2005-05-31 01:36:53	2	2006-02-15 21:30:53
660	2005-05-28 20:53:31	1414	578	2005-05-30 15:26:31	1	2006-02-15 21:30:53
661	2005-05-28 21:01:25	2247	51	2005-06-02 01:22:25	2	2006-02-15 21:30:53
662	2005-05-28 21:09:31	2968	166	2005-06-01 19:00:31	2	2006-02-15 21:30:53
663	2005-05-28 21:23:02	3997	176	2005-06-02 17:39:02	2	2006-02-15 21:30:53
664	2005-05-28 21:31:08	87	523	2005-06-02 20:56:08	2	2006-02-15 21:30:53
665	2005-05-28 21:38:39	1012	415	2005-05-29 21:37:39	1	2006-02-15 21:30:53
666	2005-05-28 21:48:51	3075	437	2005-06-05 16:45:51	2	2006-02-15 21:30:53
667	2005-05-28 21:49:02	797	596	2005-05-31 03:07:02	1	2006-02-15 21:30:53
668	2005-05-28 21:54:45	3528	484	2005-05-29 22:32:45	1	2006-02-15 21:30:53
669	2005-05-28 22:03:25	3677	313	2005-06-03 03:39:25	1	2006-02-15 21:30:53
670	2005-05-28 22:04:03	227	201	2005-06-06 22:43:03	2	2006-02-15 21:30:53
671	2005-05-28 22:04:30	1027	14	2005-06-03 01:21:30	2	2006-02-15 21:30:53
672	2005-05-28 22:05:29	697	306	2005-06-06 02:10:29	2	2006-02-15 21:30:53
673	2005-05-28 22:07:30	1769	468	2005-06-01 23:42:30	1	2006-02-15 21:30:53
674	2005-05-28 22:11:35	1150	87	2005-06-01 23:58:35	2	2006-02-15 21:30:53
675	2005-05-28 22:22:44	1273	338	2005-06-01 02:57:44	2	2006-02-15 21:30:53
676	2005-05-28 22:27:51	2329	490	2005-05-29 20:36:51	2	2006-02-15 21:30:53
677	2005-05-28 23:00:08	4558	194	2005-06-05 19:11:08	2	2006-02-15 21:30:53
678	2005-05-28 23:15:48	3741	269	2005-06-03 04:43:48	2	2006-02-15 21:30:53
679	2005-05-28 23:24:57	907	526	2005-06-06 21:59:57	2	2006-02-15 21:30:53
680	2005-05-28 23:27:26	4147	482	2005-06-02 02:28:26	2	2006-02-15 21:30:53
681	2005-05-28 23:39:44	3346	531	2005-06-01 01:42:44	1	2006-02-15 21:30:53
682	2005-05-28 23:53:18	3160	148	2005-05-29 19:14:18	2	2006-02-15 21:30:53
683	2005-05-29 00:09:48	2038	197	2005-06-02 04:27:48	1	2006-02-15 21:30:53
684	2005-05-29 00:13:15	3242	461	2005-06-04 21:26:15	2	2006-02-15 21:30:53
685	2005-05-29 00:17:51	1385	172	2005-06-05 05:32:51	2	2006-02-15 21:30:53
686	2005-05-29 00:27:10	2441	411	2005-05-30 02:29:10	1	2006-02-15 21:30:53
687	2005-05-29 00:32:09	1731	250	2005-05-31 23:53:09	1	2006-02-15 21:30:53
688	2005-05-29 00:45:24	4135	162	2005-06-02 01:30:24	1	2006-02-15 21:30:53
689	2005-05-29 00:46:53	742	571	2005-06-03 23:48:53	2	2006-02-15 21:30:53
690	2005-05-29 00:54:53	2646	85	2005-06-06 00:45:53	1	2006-02-15 21:30:53
691	2005-05-29 01:01:26	4034	433	2005-06-07 06:21:26	1	2006-02-15 21:30:53
692	2005-05-29 01:32:10	800	18	2005-06-02 03:54:10	2	2006-02-15 21:30:53
693	2005-05-29 01:42:31	635	190	2005-06-03 02:29:31	2	2006-02-15 21:30:53
694	2005-05-29 01:49:43	592	399	2005-06-05 06:52:43	1	2006-02-15 21:30:53
695	2005-05-29 01:50:53	4276	528	2005-06-03 02:28:53	1	2006-02-15 21:30:53
696	2005-05-29 01:59:10	2076	19	2005-06-01 02:45:10	1	2006-02-15 21:30:53
697	2005-05-29 02:04:04	3949	387	2005-06-04 00:47:04	2	2006-02-15 21:30:53
698	2005-05-29 02:10:52	1412	109	2005-06-01 21:52:52	1	2006-02-15 21:30:53
699	2005-05-29 02:11:44	130	246	2005-06-04 20:23:44	2	2006-02-15 21:30:53
700	2005-05-29 02:18:54	500	117	2005-05-30 05:54:54	1	2006-02-15 21:30:53
701	2005-05-29 02:26:27	372	112	2005-06-03 04:59:27	1	2006-02-15 21:30:53
702	2005-05-29 02:27:30	2556	475	2005-05-30 01:52:30	2	2006-02-15 21:30:53
703	2005-05-29 02:29:36	1123	269	2005-06-03 04:54:36	2	2006-02-15 21:30:53
704	2005-05-29 02:44:43	2628	330	2005-06-06 01:51:43	2	2006-02-15 21:30:53
705	2005-05-29 02:48:52	2809	257	2005-05-30 06:21:52	1	2006-02-15 21:30:53
706	2005-05-29 03:05:49	2278	60	2005-06-04 22:48:49	1	2006-02-15 21:30:53
707	2005-05-29 03:18:19	819	252	2005-05-30 02:45:19	1	2006-02-15 21:30:53
708	2005-05-29 03:23:47	3133	127	2005-05-31 21:27:47	2	2006-02-15 21:30:53
709	2005-05-29 03:48:01	2459	479	2005-06-06 05:21:01	1	2006-02-15 21:30:53
710	2005-05-29 03:48:36	194	518	2005-06-03 05:03:36	1	2006-02-15 21:30:53
711	2005-05-29 03:49:03	4581	215	2005-05-31 08:29:03	2	2006-02-15 21:30:53
712	2005-05-29 04:02:24	4191	313	2005-05-30 03:09:24	2	2006-02-15 21:30:53
713	2005-05-29 04:10:17	3664	507	2005-06-07 07:13:17	1	2006-02-15 21:30:53
714	2005-05-29 04:15:21	2010	452	2005-06-01 23:05:21	2	2006-02-15 21:30:53
715	2005-05-29 04:22:41	2030	545	2005-06-05 09:28:41	1	2006-02-15 21:30:53
716	2005-05-29 04:35:29	85	36	2005-06-01 07:42:29	2	2006-02-15 21:30:53
717	2005-05-29 04:37:44	1383	412	2005-05-30 05:48:44	2	2006-02-15 21:30:53
718	2005-05-29 04:52:23	1736	498	2005-06-02 02:27:23	1	2006-02-15 21:30:53
719	2005-05-29 05:16:05	267	245	2005-06-01 07:53:05	2	2006-02-15 21:30:53
720	2005-05-29 05:17:30	3687	480	2005-06-06 02:47:30	2	2006-02-15 21:30:53
721	2005-05-29 05:28:47	1116	44	2005-05-31 11:24:47	1	2006-02-15 21:30:53
722	2005-05-29 05:30:31	4540	259	2005-06-06 04:51:31	1	2006-02-15 21:30:53
723	2005-05-29 05:34:44	3407	309	2005-05-30 05:50:44	1	2006-02-15 21:30:53
724	2005-05-29 05:53:23	3770	416	2005-06-05 04:01:23	2	2006-02-15 21:30:53
725	2005-05-29 06:03:41	4088	245	2005-06-03 08:52:41	2	2006-02-15 21:30:53
726	2005-05-29 06:05:29	933	452	2005-06-05 04:40:29	2	2006-02-15 21:30:53
727	2005-05-29 06:08:15	1629	484	2005-05-30 07:16:15	1	2006-02-15 21:30:53
728	2005-05-29 06:12:38	242	551	2005-06-03 07:41:38	1	2006-02-15 21:30:53
729	2005-05-29 06:35:13	1688	323	2005-06-04 03:23:13	2	2006-02-15 21:30:53
730	2005-05-29 07:00:59	3473	197	2005-06-06 01:17:59	1	2006-02-15 21:30:53
731	2005-05-29 07:25:16	4124	5	2005-05-30 05:21:16	1	2006-02-15 21:30:53
732	2005-05-29 07:32:51	2530	447	2005-05-30 10:08:51	2	2006-02-15 21:30:53
733	2005-05-29 07:35:21	2951	363	2005-06-05 09:14:21	1	2006-02-15 21:30:53
734	2005-05-29 07:38:52	3084	538	2005-06-03 10:17:52	2	2006-02-15 21:30:53
735	2005-05-29 08:08:13	3421	454	2005-06-07 13:35:13	1	2006-02-15 21:30:53
736	2005-05-29 08:10:07	3689	276	2005-06-05 10:21:07	2	2006-02-15 21:30:53
737	2005-05-29 08:11:31	769	589	2005-06-04 11:18:31	2	2006-02-15 21:30:53
738	2005-05-29 08:20:08	2284	256	2005-06-06 08:59:08	2	2006-02-15 21:30:53
739	2005-05-29 08:28:18	1183	84	2005-06-06 09:21:18	2	2006-02-15 21:30:53
740	2005-05-29 08:30:36	600	89	2005-06-04 12:47:36	2	2006-02-15 21:30:53
741	2005-05-29 08:35:49	3189	495	2005-06-04 11:55:49	1	2006-02-15 21:30:53
742	2005-05-29 08:36:30	273	483	2005-06-05 11:30:30	1	2006-02-15 21:30:53
743	2005-05-29 08:39:02	2528	548	2005-06-06 08:42:02	2	2006-02-15 21:30:53
744	2005-05-29 09:13:08	3722	420	2005-06-01 07:05:08	2	2006-02-15 21:30:53
745	2005-05-29 09:22:57	581	152	2005-06-01 09:10:57	1	2006-02-15 21:30:53
746	2005-05-29 09:25:10	4272	130	2005-06-02 04:20:10	2	2006-02-15 21:30:53
747	2005-05-29 09:26:34	1993	291	2005-06-05 07:28:34	1	2006-02-15 21:30:53
748	2005-05-29 09:27:00	2803	7	2005-06-03 04:25:00	1	2006-02-15 21:30:53
749	2005-05-29 09:33:33	1146	375	2005-05-31 11:45:33	2	2006-02-15 21:30:53
750	2005-05-29 09:41:40	730	269	2005-05-30 13:31:40	1	2006-02-15 21:30:53
751	2005-05-29 09:55:43	2711	53	2005-06-02 04:54:43	1	2006-02-15 21:30:53
752	2005-05-29 10:14:15	1720	126	2005-06-04 06:30:15	1	2006-02-15 21:30:53
753	2005-05-29 10:16:42	1021	135	2005-06-05 08:52:42	2	2006-02-15 21:30:53
754	2005-05-29 10:18:59	734	281	2005-06-04 05:03:59	2	2006-02-15 21:30:53
755	2005-05-29 10:26:29	3090	576	2005-06-01 10:25:29	2	2006-02-15 21:30:53
756	2005-05-29 10:28:45	3152	201	2005-06-04 12:50:45	1	2006-02-15 21:30:53
757	2005-05-29 10:29:47	1067	435	2005-06-07 15:27:47	1	2006-02-15 21:30:53
758	2005-05-29 10:31:56	1191	563	2005-06-01 14:53:56	2	2006-02-15 21:30:53
759	2005-05-29 10:57:57	2367	179	2005-06-07 16:23:57	2	2006-02-15 21:30:53
760	2005-05-29 11:07:25	3250	77	2005-06-02 14:16:25	1	2006-02-15 21:30:53
761	2005-05-29 11:09:01	2342	58	2005-06-03 16:18:01	2	2006-02-15 21:30:53
762	2005-05-29 11:15:51	3683	146	2005-06-06 07:48:51	1	2006-02-15 21:30:53
763	2005-05-29 11:32:15	2022	50	2005-05-31 17:31:15	1	2006-02-15 21:30:53
764	2005-05-29 11:37:35	1069	149	2005-05-31 16:47:35	1	2006-02-15 21:30:53
765	2005-05-29 11:38:34	515	69	2005-06-02 17:04:34	1	2006-02-15 21:30:53
766	2005-05-29 11:47:02	2154	383	2005-06-06 07:14:02	1	2006-02-15 21:30:53
767	2005-05-29 12:20:19	687	67	2005-06-02 14:15:19	2	2006-02-15 21:30:53
768	2005-05-29 12:30:46	2895	566	2005-06-07 09:00:46	2	2006-02-15 21:30:53
769	2005-05-29 12:51:44	1523	575	2005-06-01 17:43:44	1	2006-02-15 21:30:53
770	2005-05-29 12:56:50	2491	405	2005-06-07 15:54:50	2	2006-02-15 21:30:53
771	2005-05-29 12:59:14	353	476	2005-06-01 16:05:14	2	2006-02-15 21:30:53
772	2005-05-29 13:08:06	3319	556	2005-06-06 08:19:06	1	2006-02-15 21:30:53
773	2005-05-29 13:18:05	245	563	2005-06-07 17:22:05	1	2006-02-15 21:30:53
774	2005-05-29 13:19:43	1188	575	2005-06-01 18:51:43	1	2006-02-15 21:30:53
775	2005-05-29 13:23:26	1197	124	2005-05-30 07:53:26	2	2006-02-15 21:30:53
776	2005-05-29 13:35:35	4339	113	2005-06-03 17:33:35	1	2006-02-15 21:30:53
777	2005-05-29 14:07:58	451	360	2005-06-03 08:41:58	2	2006-02-15 21:30:53
778	2005-05-29 14:09:53	1816	535	2005-06-05 20:05:53	1	2006-02-15 21:30:53
779	2005-05-29 14:17:17	533	105	2005-06-06 16:46:17	1	2006-02-15 21:30:53
780	2005-05-29 14:18:32	1919	300	2005-06-06 20:14:32	1	2006-02-15 21:30:53
781	2005-05-29 14:23:58	88	313	2005-05-30 17:44:58	1	2006-02-15 21:30:53
782	2005-05-29 14:38:57	2255	596	2005-06-02 13:18:57	2	2006-02-15 21:30:53
783	2005-05-29 14:41:18	3046	53	2005-06-06 10:39:18	2	2006-02-15 21:30:53
784	2005-05-29 14:44:22	2936	352	2005-06-01 17:28:22	2	2006-02-15 21:30:53
785	2005-05-29 15:08:41	39	72	2005-05-30 15:51:41	1	2006-02-15 21:30:53
786	2005-05-29 15:17:28	2637	439	2005-06-07 10:07:28	2	2006-02-15 21:30:53
787	2005-05-29 16:03:03	3919	27	2005-06-07 11:07:03	2	2006-02-15 21:30:53
788	2005-05-29 16:13:55	763	562	2005-05-31 16:40:55	1	2006-02-15 21:30:53
789	2005-05-29 16:17:07	708	553	2005-06-06 18:15:07	1	2006-02-15 21:30:53
790	2005-05-29 16:19:29	2858	593	2005-06-02 17:22:29	2	2006-02-15 21:30:53
791	2005-05-29 16:30:42	1554	284	2005-06-01 19:11:42	1	2006-02-15 21:30:53
792	2005-05-29 16:32:10	2841	261	2005-05-31 18:01:10	1	2006-02-15 21:30:53
793	2005-05-29 16:44:08	379	528	2005-06-06 19:21:08	2	2006-02-15 21:30:53
794	2005-05-29 16:44:11	1995	50	2005-06-05 16:11:11	1	2006-02-15 21:30:53
795	2005-05-29 16:57:39	609	551	2005-06-01 11:33:39	2	2006-02-15 21:30:53
796	2005-05-29 16:59:44	2697	26	2005-06-03 16:22:44	2	2006-02-15 21:30:53
797	2005-05-29 17:12:17	1446	244	2005-06-03 16:06:17	1	2006-02-15 21:30:53
798	2005-05-29 17:23:43	1102	134	2005-06-01 13:06:43	2	2006-02-15 21:30:53
799	2005-05-29 17:24:48	1713	429	2005-06-05 12:25:48	1	2006-02-15 21:30:53
800	2005-05-29 17:28:12	441	472	2005-05-30 14:59:12	1	2006-02-15 21:30:53
801	2005-05-29 17:35:50	1642	402	2005-06-04 17:05:50	2	2006-02-15 21:30:53
802	2005-05-29 17:38:59	785	350	2005-05-31 22:42:59	2	2006-02-15 21:30:53
803	2005-05-29 17:52:30	1602	32	2005-05-30 14:35:30	2	2006-02-15 21:30:53
804	2005-05-29 18:10:24	3909	171	2005-06-06 22:53:24	1	2006-02-15 21:30:53
805	2005-05-29 18:18:18	3132	232	2005-06-07 15:11:18	2	2006-02-15 21:30:53
806	2005-05-29 18:31:30	2386	435	2005-05-31 00:18:30	2	2006-02-15 21:30:53
807	2005-05-29 18:50:50	2195	235	2005-06-03 18:36:50	2	2006-02-15 21:30:53
808	2005-05-29 19:08:20	1928	104	2005-06-06 20:32:20	2	2006-02-15 21:30:53
809	2005-05-29 19:10:20	2114	222	2005-06-05 19:05:20	2	2006-02-15 21:30:53
810	2005-05-29 19:12:04	2533	346	2005-06-04 21:12:04	2	2006-02-15 21:30:53
811	2005-05-29 19:30:42	4419	401	2005-06-02 16:19:42	2	2006-02-15 21:30:53
812	2005-05-29 20:00:30	1099	225	2005-05-30 19:43:30	2	2006-02-15 21:30:53
813	2005-05-29 20:14:34	4554	344	2005-06-05 20:56:34	1	2006-02-15 21:30:53
814	2005-05-29 20:16:12	1572	134	2005-06-07 17:47:12	1	2006-02-15 21:30:53
815	2005-05-29 20:24:28	3757	14	2005-06-03 15:32:28	1	2006-02-15 21:30:53
816	2005-05-29 20:26:39	630	474	2005-06-06 22:31:39	2	2006-02-15 21:30:53
817	2005-05-29 20:39:14	186	554	2005-05-31 18:24:14	1	2006-02-15 21:30:53
818	2005-05-29 20:47:53	4106	321	2005-06-02 23:18:53	2	2006-02-15 21:30:53
819	2005-05-29 21:00:32	623	511	2005-06-02 15:15:32	2	2006-02-15 21:30:53
820	2005-05-29 21:07:22	2584	22	2005-06-07 00:22:22	2	2006-02-15 21:30:53
821	2005-05-29 21:31:12	3380	348	2005-06-04 22:49:12	1	2006-02-15 21:30:53
822	2005-05-29 21:36:00	2634	480	2005-06-07 17:24:00	1	2006-02-15 21:30:53
823	2005-05-29 21:39:37	3249	441	2005-05-30 22:06:37	1	2006-02-15 21:30:53
824	2005-05-29 21:45:32	3518	357	2005-05-31 19:01:32	1	2006-02-15 21:30:53
825	2005-05-29 21:49:41	712	371	2005-06-04 20:27:41	2	2006-02-15 21:30:53
826	2005-05-29 21:56:15	2263	207	2005-06-08 03:18:15	1	2006-02-15 21:30:53
827	2005-05-29 21:58:43	62	573	2005-06-06 00:54:43	1	2006-02-15 21:30:53
828	2005-05-29 22:14:55	2468	217	2005-05-30 17:22:55	1	2006-02-15 21:30:53
829	2005-05-29 22:16:42	1684	371	2005-06-06 01:38:42	1	2006-02-15 21:30:53
830	2005-05-29 22:43:55	3464	3	2005-06-01 17:43:55	1	2006-02-15 21:30:53
831	2005-05-29 22:50:25	3912	509	2005-06-06 02:27:25	1	2006-02-15 21:30:53
832	2005-05-29 22:51:20	1381	159	2005-06-07 17:37:20	2	2006-02-15 21:30:53
833	2005-05-29 23:21:56	2898	417	2005-06-02 18:40:56	1	2006-02-15 21:30:53
834	2005-05-29 23:24:30	3628	84	2005-05-30 22:00:30	2	2006-02-15 21:30:53
835	2005-05-29 23:37:00	299	381	2005-06-02 23:38:00	1	2006-02-15 21:30:53
836	2005-05-29 23:56:42	3140	368	2005-05-31 04:11:42	2	2006-02-15 21:30:53
837	2005-05-30 00:02:08	977	172	2005-06-02 05:31:08	2	2006-02-15 21:30:53
838	2005-05-30 00:27:57	2859	504	2005-06-06 22:19:57	2	2006-02-15 21:30:53
839	2005-05-30 00:28:12	1886	337	2005-06-08 02:43:12	1	2006-02-15 21:30:53
840	2005-05-30 00:28:41	4049	79	2005-05-31 20:39:41	2	2006-02-15 21:30:53
841	2005-05-30 00:31:17	4318	387	2005-06-02 19:14:17	1	2006-02-15 21:30:53
842	2005-05-30 00:32:04	2328	238	2005-06-01 02:21:04	1	2006-02-15 21:30:53
843	2005-05-30 00:44:24	2214	313	2005-05-31 00:58:24	2	2006-02-15 21:30:53
844	2005-05-30 00:58:20	536	429	2005-06-01 00:38:20	1	2006-02-15 21:30:53
845	2005-05-30 01:17:25	2001	72	2005-06-07 02:00:25	1	2006-02-15 21:30:53
846	2005-05-30 01:17:45	938	49	2005-06-01 00:56:45	2	2006-02-15 21:30:53
847	2005-05-30 01:18:15	4387	380	2005-06-06 20:20:15	2	2006-02-15 21:30:53
848	2005-05-30 01:19:53	1363	436	2005-06-05 23:40:53	1	2006-02-15 21:30:53
849	2005-05-30 01:23:07	2424	449	2005-06-07 01:50:07	1	2006-02-15 21:30:53
850	2005-05-30 01:35:12	2390	517	2005-05-31 01:51:12	1	2006-02-15 21:30:53
851	2005-05-30 01:35:15	2780	530	2005-06-06 07:27:15	1	2006-02-15 21:30:53
852	2005-05-30 01:36:57	1622	549	2005-06-01 22:44:57	1	2006-02-15 21:30:53
853	2005-05-30 01:43:31	3693	122	2005-06-01 02:05:31	1	2006-02-15 21:30:53
854	2005-05-30 01:56:11	921	369	2005-06-01 06:34:11	2	2006-02-15 21:30:53
855	2005-05-30 02:00:28	2527	406	2005-06-03 20:16:28	2	2006-02-15 21:30:53
856	2005-05-30 02:01:21	3969	53	2005-06-07 03:25:21	1	2006-02-15 21:30:53
857	2005-05-30 02:01:23	2569	204	2005-06-02 06:07:23	2	2006-02-15 21:30:53
858	2005-05-30 02:10:32	1258	358	2005-06-01 04:42:32	1	2006-02-15 21:30:53
859	2005-05-30 02:36:20	3032	79	2005-06-02 07:49:20	2	2006-02-15 21:30:53
860	2005-05-30 02:45:16	578	276	2005-06-08 07:28:16	1	2006-02-15 21:30:53
861	2005-05-30 02:48:32	3711	502	2005-06-06 05:43:32	1	2006-02-15 21:30:53
862	2005-05-30 03:09:11	1186	328	2005-06-03 21:27:11	1	2006-02-15 21:30:53
863	2005-05-30 03:14:59	3999	379	2005-06-05 04:34:59	2	2006-02-15 21:30:53
864	2005-05-30 03:27:17	2777	544	2005-06-06 08:28:17	1	2006-02-15 21:30:53
865	2005-05-30 03:39:44	3183	154	2005-06-07 08:10:44	2	2006-02-15 21:30:53
866	2005-05-30 03:43:54	2867	8	2005-06-08 04:28:54	1	2006-02-15 21:30:53
867	2005-05-30 03:54:43	3389	99	2005-06-01 22:59:43	1	2006-02-15 21:30:53
868	2005-05-30 04:19:55	3604	28	2005-05-31 02:28:55	1	2006-02-15 21:30:53
869	2005-05-30 04:22:06	3399	296	2005-06-03 09:18:06	2	2006-02-15 21:30:53
870	2005-05-30 04:25:47	2903	391	2005-06-06 04:32:47	1	2006-02-15 21:30:53
871	2005-05-30 05:01:30	4573	303	2005-06-04 06:22:30	2	2006-02-15 21:30:53
872	2005-05-30 05:03:04	3904	548	2005-06-06 10:35:04	1	2006-02-15 21:30:53
873	2005-05-30 05:15:20	4568	375	2005-06-07 00:49:20	2	2006-02-15 21:30:53
874	2005-05-30 05:36:21	363	52	2005-06-01 09:32:21	1	2006-02-15 21:30:53
875	2005-05-30 05:38:24	1428	326	2005-06-06 00:34:24	2	2006-02-15 21:30:53
876	2005-05-30 05:41:22	1471	339	2005-06-07 09:06:22	2	2006-02-15 21:30:53
877	2005-05-30 05:48:59	886	9	2005-06-02 09:30:59	1	2006-02-15 21:30:53
878	2005-05-30 05:49:13	4265	323	2005-06-07 04:35:13	1	2006-02-15 21:30:53
879	2005-05-30 05:49:42	4021	482	2005-06-05 01:45:42	2	2006-02-15 21:30:53
880	2005-05-30 06:12:33	1819	460	2005-06-02 04:35:33	2	2006-02-15 21:30:53
881	2005-05-30 06:15:36	602	242	2005-06-02 10:21:36	1	2006-02-15 21:30:53
882	2005-05-30 06:16:06	3841	477	2005-06-02 11:57:06	1	2006-02-15 21:30:53
883	2005-05-30 06:21:05	2271	399	2005-06-07 04:50:05	2	2006-02-15 21:30:53
884	2005-05-30 06:41:32	4079	17	2005-05-31 07:39:32	1	2006-02-15 21:30:53
885	2005-05-30 06:54:28	646	62	2005-06-03 07:03:28	2	2006-02-15 21:30:53
886	2005-05-30 06:54:51	4356	393	2005-06-01 06:04:51	2	2006-02-15 21:30:53
887	2005-05-30 07:10:00	2727	16	2005-06-01 06:48:00	2	2006-02-15 21:30:53
888	2005-05-30 07:13:14	387	128	2005-06-06 09:50:14	1	2006-02-15 21:30:53
889	2005-05-30 07:14:53	1299	114	2005-05-31 07:56:53	2	2006-02-15 21:30:53
890	2005-05-30 07:43:04	1464	349	2005-06-01 11:26:04	1	2006-02-15 21:30:53
891	2005-05-30 07:43:12	2611	391	2005-06-08 09:21:12	1	2006-02-15 21:30:53
892	2005-05-30 08:02:56	471	274	2005-06-05 12:51:56	1	2006-02-15 21:30:53
893	2005-05-30 08:06:59	3260	502	2005-06-07 08:23:59	2	2006-02-15 21:30:53
894	2005-05-30 08:31:31	1118	400	2005-06-07 12:39:31	1	2006-02-15 21:30:53
895	2005-05-30 08:50:43	2744	192	2005-06-05 10:58:43	1	2006-02-15 21:30:53
896	2005-05-30 09:03:52	2817	207	2005-06-05 07:37:52	2	2006-02-15 21:30:53
897	2005-05-30 09:10:01	1334	432	2005-06-08 03:43:01	1	2006-02-15 21:30:53
898	2005-05-30 09:26:19	3497	384	2005-06-01 10:45:19	2	2006-02-15 21:30:53
899	2005-05-30 09:29:30	1096	156	2005-06-06 12:39:30	2	2006-02-15 21:30:53
900	2005-05-30 09:38:41	3543	586	2005-06-07 11:54:41	1	2006-02-15 21:30:53
901	2005-05-30 09:40:40	760	259	2005-06-02 10:32:40	1	2006-02-15 21:30:53
902	2005-05-30 09:53:36	1514	561	2005-06-07 12:10:36	1	2006-02-15 21:30:53
903	2005-05-30 10:11:29	2423	197	2005-06-03 09:33:29	1	2006-02-15 21:30:53
904	2005-05-30 10:19:42	2466	44	2005-06-05 04:58:42	2	2006-02-15 21:30:53
905	2005-05-30 10:25:00	4372	50	2005-06-06 06:23:00	1	2006-02-15 21:30:53
906	2005-05-30 10:30:38	1862	549	2005-06-07 06:44:38	2	2006-02-15 21:30:53
907	2005-05-30 10:37:27	3320	506	2005-06-02 09:51:27	1	2006-02-15 21:30:53
908	2005-05-30 10:38:37	4427	85	2005-06-03 09:56:37	1	2006-02-15 21:30:53
909	2005-05-30 10:43:38	3775	486	2005-06-08 12:07:38	1	2006-02-15 21:30:53
910	2005-05-30 10:46:16	2601	374	2005-06-04 13:32:16	1	2006-02-15 21:30:53
911	2005-05-30 10:50:22	1404	366	2005-06-07 12:26:22	2	2006-02-15 21:30:53
912	2005-05-30 10:58:33	3200	390	2005-05-31 09:31:33	2	2006-02-15 21:30:53
913	2005-05-30 11:04:58	3213	369	2005-06-07 13:22:58	2	2006-02-15 21:30:53
914	2005-05-30 11:06:00	1393	596	2005-06-04 06:07:00	2	2006-02-15 21:30:53
915	2005-05-30 11:20:27	1859	115	2005-06-02 11:55:27	1	2006-02-15 21:30:53
916	2005-05-30 11:25:01	1290	6	2005-05-31 09:06:01	1	2006-02-15 21:30:53
917	2005-05-30 11:27:06	3629	385	2005-06-02 08:31:06	1	2006-02-15 21:30:53
918	2005-05-30 11:32:24	818	197	2005-05-31 07:55:24	2	2006-02-15 21:30:53
919	2005-05-30 11:35:06	4052	374	2005-06-02 13:16:06	2	2006-02-15 21:30:53
920	2005-05-30 11:44:01	3860	584	2005-06-02 08:19:01	2	2006-02-15 21:30:53
921	2005-05-30 11:53:09	1827	508	2005-06-03 10:00:09	2	2006-02-15 21:30:53
922	2005-05-30 11:55:55	2442	550	2005-06-08 10:12:55	2	2006-02-15 21:30:53
923	2005-05-30 11:58:50	1884	37	2005-06-05 09:57:50	1	2006-02-15 21:30:53
924	2005-05-30 12:10:59	3279	293	2005-06-04 17:28:59	1	2006-02-15 21:30:53
925	2005-05-30 12:13:52	3203	137	2005-06-02 14:41:52	2	2006-02-15 21:30:53
926	2005-05-30 12:15:54	4327	76	2005-06-01 08:53:54	2	2006-02-15 21:30:53
927	2005-05-30 12:16:40	1158	167	2005-05-31 16:20:40	2	2006-02-15 21:30:53
928	2005-05-30 12:27:14	246	79	2005-06-05 13:56:14	2	2006-02-15 21:30:53
929	2005-05-30 12:32:39	4296	536	2005-06-06 12:17:39	1	2006-02-15 21:30:53
930	2005-05-30 12:44:57	2835	141	2005-06-04 10:53:57	2	2006-02-15 21:30:53
931	2005-05-30 12:53:01	3384	421	2005-05-31 14:28:01	1	2006-02-15 21:30:53
932	2005-05-30 12:55:36	719	198	2005-05-31 10:30:36	2	2006-02-15 21:30:53
933	2005-05-30 13:08:45	3672	66	2005-06-01 18:56:45	1	2006-02-15 21:30:53
934	2005-05-30 13:24:46	3595	60	2005-06-08 16:44:46	2	2006-02-15 21:30:53
935	2005-05-30 13:29:36	2421	256	2005-06-02 11:08:36	1	2006-02-15 21:30:53
936	2005-05-30 13:52:49	901	469	2005-06-07 16:56:49	1	2006-02-15 21:30:53
937	2005-05-30 14:47:31	1054	304	2005-06-05 09:53:31	2	2006-02-15 21:30:53
938	2005-05-30 14:47:31	1521	46	2005-06-04 10:10:31	2	2006-02-15 21:30:53
939	2005-05-30 14:49:34	1314	367	2005-06-01 19:00:34	1	2006-02-15 21:30:53
940	2005-05-30 15:01:02	1278	534	2005-06-01 18:26:02	1	2006-02-15 21:30:53
941	2005-05-30 15:02:25	3630	562	2005-06-01 17:19:25	1	2006-02-15 21:30:53
942	2005-05-30 15:05:47	4279	473	2005-06-08 15:59:47	2	2006-02-15 21:30:53
943	2005-05-30 15:20:19	3737	57	2005-06-06 18:53:19	1	2006-02-15 21:30:53
944	2005-05-30 15:26:24	151	131	2005-06-07 18:09:24	2	2006-02-15 21:30:53
945	2005-05-30 15:33:17	1441	357	2005-06-02 15:02:17	2	2006-02-15 21:30:53
946	2005-05-30 15:35:08	1264	486	2005-06-08 11:38:08	1	2006-02-15 21:30:53
947	2005-05-30 15:36:57	4478	62	2005-06-04 18:48:57	1	2006-02-15 21:30:53
948	2005-05-30 15:44:27	585	245	2005-06-08 17:30:27	2	2006-02-15 21:30:53
949	2005-05-30 15:50:39	2202	368	2005-06-03 14:25:39	1	2006-02-15 21:30:53
950	2005-05-30 16:06:08	491	83	2005-06-01 11:43:08	1	2006-02-15 21:30:53
951	2005-05-30 16:10:35	1395	59	2005-05-31 19:01:35	2	2006-02-15 21:30:53
952	2005-05-30 16:28:07	4389	311	2005-06-02 16:12:07	2	2006-02-15 21:30:53
953	2005-05-30 16:34:02	2194	210	2005-05-31 20:34:02	1	2006-02-15 21:30:53
954	2005-05-30 16:57:29	1231	297	2005-06-08 13:30:29	2	2006-02-15 21:30:53
955	2005-05-30 16:59:03	4140	301	2005-05-31 11:58:03	2	2006-02-15 21:30:53
956	2005-05-30 17:30:28	647	296	2005-06-07 13:54:28	2	2006-02-15 21:30:53
957	2005-05-30 17:53:29	4428	440	2005-06-03 15:31:29	2	2006-02-15 21:30:53
958	2005-05-30 17:58:03	548	186	2005-06-01 19:17:03	2	2006-02-15 21:30:53
959	2005-05-30 18:07:00	3108	535	2005-06-02 14:37:00	2	2006-02-15 21:30:53
960	2005-05-30 18:13:23	1966	445	2005-06-04 00:12:23	2	2006-02-15 21:30:53
961	2005-05-30 18:16:44	3293	588	2005-06-04 23:40:44	2	2006-02-15 21:30:53
962	2005-05-30 18:45:17	4535	520	2005-06-05 22:47:17	1	2006-02-15 21:30:53
963	2005-05-30 18:52:53	1921	225	2005-06-07 16:19:53	2	2006-02-15 21:30:53
964	2005-05-30 18:53:21	657	287	2005-06-04 22:32:21	2	2006-02-15 21:30:53
965	2005-05-30 19:00:14	3363	502	2005-05-31 17:10:14	2	2006-02-15 21:30:53
966	2005-05-30 19:00:37	1294	496	2005-05-31 23:51:37	1	2006-02-15 21:30:53
967	2005-05-30 19:12:06	1954	330	2005-06-09 00:02:06	2	2006-02-15 21:30:53
968	2005-05-30 19:20:03	119	576	2005-05-31 18:17:03	2	2006-02-15 21:30:53
969	2005-05-30 19:23:48	443	551	2005-05-31 21:14:48	1	2006-02-15 21:30:53
970	2005-05-30 19:50:28	1520	307	2005-06-09 01:19:28	1	2006-02-15 21:30:53
971	2005-05-30 20:10:52	2911	561	2005-06-06 20:47:52	1	2006-02-15 21:30:53
972	2005-05-30 20:21:07	2	411	2005-06-06 00:36:07	1	2006-02-15 21:30:53
973	2005-05-30 20:27:45	1914	473	2005-06-08 22:47:45	2	2006-02-15 21:30:53
974	2005-05-30 20:28:42	2617	596	2005-06-08 23:45:42	2	2006-02-15 21:30:53
975	2005-05-30 21:07:15	3109	7	2005-06-03 01:48:15	2	2006-02-15 21:30:53
976	2005-05-30 21:11:19	2290	581	2005-06-06 02:16:19	2	2006-02-15 21:30:53
977	2005-05-30 21:22:26	2029	394	2005-06-04 22:32:26	2	2006-02-15 21:30:53
978	2005-05-30 21:30:52	407	154	2005-06-07 16:22:52	1	2006-02-15 21:30:53
979	2005-05-30 21:37:11	3917	279	2005-06-08 00:24:11	2	2006-02-15 21:30:53
980	2005-05-30 21:45:19	4169	273	2005-06-01 20:32:19	1	2006-02-15 21:30:53
981	2005-05-30 21:52:42	2913	326	2005-06-01 03:15:42	2	2006-02-15 21:30:53
982	2005-05-30 22:15:24	3560	524	2005-06-02 16:18:24	1	2006-02-15 21:30:53
983	2005-05-30 22:15:51	63	115	2005-06-02 22:56:51	1	2006-02-15 21:30:53
984	2005-05-30 22:17:17	2305	262	2005-06-01 20:15:17	2	2006-02-15 21:30:53
985	2005-05-30 22:18:35	1573	564	2005-06-04 23:36:35	1	2006-02-15 21:30:53
986	2005-05-30 22:22:52	4045	253	2005-06-01 02:24:52	1	2006-02-15 21:30:53
987	2005-05-30 22:59:12	390	11	2005-06-07 20:56:12	1	2006-02-15 21:30:53
988	2005-05-30 23:08:03	1364	12	2005-06-07 00:22:03	1	2006-02-15 21:30:53
989	2005-05-30 23:11:51	4388	83	2005-06-03 20:36:51	2	2006-02-15 21:30:53
990	2005-05-30 23:25:14	4171	311	2005-06-06 18:41:14	2	2006-02-15 21:30:53
991	2005-05-30 23:29:22	2863	593	2005-06-07 23:16:22	1	2006-02-15 21:30:53
992	2005-05-30 23:47:56	3572	123	2005-06-05 19:01:56	1	2006-02-15 21:30:53
993	2005-05-30 23:54:19	2080	513	2005-06-04 21:27:19	1	2006-02-15 21:30:53
994	2005-05-30 23:55:36	2798	472	2005-06-04 01:00:36	2	2006-02-15 21:30:53
995	2005-05-31 00:06:02	17	150	2005-06-06 02:30:02	2	2006-02-15 21:30:53
996	2005-05-31 00:06:20	2075	331	2005-05-31 21:29:20	2	2006-02-15 21:30:53
997	2005-05-31 00:08:25	4243	216	2005-06-02 00:17:25	2	2006-02-15 21:30:53
998	2005-05-31 00:16:57	3395	389	2005-06-01 22:41:57	1	2006-02-15 21:30:53
999	2005-05-31 00:25:10	4433	413	2005-06-03 06:05:10	2	2006-02-15 21:30:53
1000	2005-05-31 00:25:56	1774	332	2005-06-08 19:42:56	2	2006-02-15 21:30:53
1001	2005-05-31 00:46:31	1498	64	2005-06-06 06:14:31	2	2006-02-15 21:30:53
1002	2005-05-31 00:47:56	709	397	2005-06-06 19:51:56	1	2006-02-15 21:30:53
1003	2005-05-31 00:48:20	133	161	2005-06-02 04:53:20	2	2006-02-15 21:30:53
1004	2005-05-31 00:48:36	1588	565	2005-06-01 20:56:36	1	2006-02-15 21:30:53
1005	2005-05-31 00:53:25	4006	551	2005-06-04 01:21:25	2	2006-02-15 21:30:53
1006	2005-05-31 00:57:08	3461	222	2005-06-02 22:35:08	1	2006-02-15 21:30:53
1007	2005-05-31 01:02:28	3185	24	2005-06-07 01:36:28	2	2006-02-15 21:30:53
1008	2005-05-31 01:18:56	914	599	2005-06-01 01:24:56	2	2006-02-15 21:30:53
1009	2005-05-31 01:47:35	2523	485	2005-06-03 20:26:35	1	2006-02-15 21:30:53
1010	2005-05-31 01:57:32	4038	49	2005-06-01 06:50:32	2	2006-02-15 21:30:53
1011	2005-05-31 02:05:39	118	164	2005-06-04 21:27:39	2	2006-02-15 21:30:53
1012	2005-05-31 02:18:05	688	291	2005-06-03 06:47:05	1	2006-02-15 21:30:53
1013	2005-05-31 02:37:00	4522	384	2005-06-02 06:39:00	2	2006-02-15 21:30:53
1014	2005-05-31 02:39:16	766	280	2005-06-01 06:03:16	2	2006-02-15 21:30:53
1015	2005-05-31 02:44:57	3702	526	2005-06-07 23:01:57	2	2006-02-15 21:30:53
1016	2005-05-31 02:49:43	3423	204	2005-06-04 03:48:43	1	2006-02-15 21:30:53
1017	2005-05-31 02:53:36	1242	16	2005-06-03 05:04:36	1	2006-02-15 21:30:53
1018	2005-05-31 02:53:42	1930	594	2005-06-03 00:47:42	2	2006-02-15 21:30:53
1019	2005-05-31 03:05:07	3975	279	2005-06-03 08:34:07	1	2006-02-15 21:30:53
1020	2005-05-31 03:06:08	3402	138	2005-06-02 08:57:08	2	2006-02-15 21:30:53
1021	2005-05-31 03:16:15	2724	541	2005-06-08 06:43:15	2	2006-02-15 21:30:53
1022	2005-05-31 03:16:45	842	239	2005-06-08 09:04:45	1	2006-02-15 21:30:53
1023	2005-05-31 03:26:50	2483	227	2005-06-05 08:19:50	2	2006-02-15 21:30:53
1024	2005-05-31 03:30:19	2310	457	2005-06-09 05:52:19	2	2006-02-15 21:30:53
1025	2005-05-31 03:41:37	1618	93	2005-06-08 07:05:37	2	2006-02-15 21:30:53
1026	2005-05-31 03:45:26	632	107	2005-06-06 22:30:26	2	2006-02-15 21:30:53
1027	2005-05-31 03:46:19	2718	55	2005-06-09 03:50:19	1	2006-02-15 21:30:53
1028	2005-05-31 03:48:05	4479	51	2005-06-01 03:51:05	1	2006-02-15 21:30:53
1029	2005-05-31 03:52:02	2082	50	2005-06-06 08:10:02	1	2006-02-15 21:30:53
1030	2005-05-31 04:06:47	3948	267	2005-06-02 02:59:47	1	2006-02-15 21:30:53
1031	2005-05-31 04:23:01	917	416	2005-06-06 08:35:01	1	2006-02-15 21:30:53
1032	2005-05-31 04:28:43	2937	236	2005-06-02 02:00:43	2	2006-02-15 21:30:53
1033	2005-05-31 04:50:07	14	25	2005-06-02 01:53:07	1	2006-02-15 21:30:53
1034	2005-05-31 04:53:40	4117	293	2005-06-09 08:25:40	2	2006-02-15 21:30:53
1035	2005-05-31 05:01:09	949	362	2005-06-02 03:59:09	1	2006-02-15 21:30:53
1036	2005-05-31 05:21:10	2164	438	2005-06-04 04:19:10	1	2006-02-15 21:30:53
1037	2005-05-31 05:22:25	810	569	2005-06-09 04:52:25	1	2006-02-15 21:30:53
1038	2005-05-31 05:23:47	1253	385	2005-06-02 03:57:47	2	2006-02-15 21:30:53
1039	2005-05-31 05:32:29	2479	124	2005-06-01 06:04:29	2	2006-02-15 21:30:53
1040	2005-05-31 05:35:16	2546	270	2005-06-09 04:14:16	1	2006-02-15 21:30:53
1041	2005-05-31 05:46:23	4432	272	2005-06-06 09:50:23	2	2006-02-15 21:30:53
1042	2005-05-31 05:53:00	3155	506	2005-06-01 05:24:00	1	2006-02-15 21:30:53
1043	2005-05-31 06:11:40	2322	412	2005-06-08 09:15:40	2	2006-02-15 21:30:53
1044	2005-05-31 06:24:44	2574	70	2005-06-03 04:51:44	1	2006-02-15 21:30:53
1045	2005-05-31 06:29:01	3470	594	2005-06-09 04:31:01	1	2006-02-15 21:30:53
1046	2005-05-31 06:42:30	468	179	2005-06-03 04:33:30	2	2006-02-15 21:30:53
1047	2005-05-31 06:45:57	1366	72	2005-06-04 09:49:57	2	2006-02-15 21:30:53
1048	2005-05-31 06:49:53	2811	55	2005-06-02 11:33:53	1	2006-02-15 21:30:53
1049	2005-05-31 06:57:04	3913	312	2005-06-02 11:32:04	2	2006-02-15 21:30:53
1050	2005-05-31 07:01:27	726	303	2005-06-03 07:50:27	2	2006-02-15 21:30:53
1051	2005-05-31 07:02:09	1025	246	2005-06-03 01:32:09	1	2006-02-15 21:30:53
1052	2005-05-31 07:07:03	2157	156	2005-06-05 09:38:03	1	2006-02-15 21:30:53
1053	2005-05-31 07:12:44	3734	196	2005-06-04 12:33:44	1	2006-02-15 21:30:53
1054	2005-05-31 07:33:25	1575	126	2005-06-02 01:40:25	2	2006-02-15 21:30:53
1055	2005-05-31 07:47:18	1639	108	2005-06-03 01:57:18	1	2006-02-15 21:30:53
1056	2005-05-31 07:48:07	1591	519	2005-06-05 08:51:07	2	2006-02-15 21:30:53
1057	2005-05-31 07:58:06	497	124	2005-06-06 03:21:06	1	2006-02-15 21:30:53
1058	2005-05-31 08:04:17	40	116	2005-06-03 11:12:17	2	2006-02-15 21:30:53
1059	2005-05-31 08:20:43	3041	241	2005-06-04 09:05:43	2	2006-02-15 21:30:53
1060	2005-05-31 08:21:43	2676	570	2005-06-09 04:02:43	2	2006-02-15 21:30:53
1061	2005-05-31 08:27:58	965	109	2005-06-07 02:34:58	1	2006-02-15 21:30:53
1062	2005-05-31 08:38:20	2223	176	2005-06-09 08:23:20	2	2006-02-15 21:30:53
1063	2005-05-31 08:44:29	2484	7	2005-06-09 08:00:29	1	2006-02-15 21:30:53
1064	2005-05-31 08:50:07	2373	460	2005-06-02 14:47:07	2	2006-02-15 21:30:53
1065	2005-05-31 08:54:56	3379	316	2005-06-08 09:21:56	1	2006-02-15 21:30:53
1066	2005-05-31 09:07:33	2383	541	2005-06-09 05:34:33	2	2006-02-15 21:30:53
1067	2005-05-31 09:12:13	2345	32	2005-06-01 06:15:13	1	2006-02-15 21:30:53
1068	2005-05-31 09:32:15	150	443	2005-06-01 11:20:15	1	2006-02-15 21:30:53
1069	2005-05-31 09:32:31	3057	251	2005-06-08 10:19:31	2	2006-02-15 21:30:53
1070	2005-05-31 09:39:56	3170	228	2005-06-05 10:23:56	1	2006-02-15 21:30:53
1071	2005-05-31 09:48:56	469	174	2005-06-02 03:52:56	2	2006-02-15 21:30:53
1072	2005-05-31 09:52:50	2557	272	2005-06-05 05:39:50	1	2006-02-15 21:30:53
1073	2005-05-31 09:55:04	522	146	2005-06-07 03:55:04	1	2006-02-15 21:30:53
1074	2005-05-31 10:04:42	2508	503	2005-06-02 15:27:42	2	2006-02-15 21:30:53
1075	2005-05-31 10:13:34	2279	9	2005-06-09 08:11:34	1	2006-02-15 21:30:53
1076	2005-05-31 10:14:31	2551	214	2005-06-05 10:13:31	2	2006-02-15 21:30:53
1077	2005-05-31 10:22:54	1986	24	2005-06-02 12:21:54	1	2006-02-15 21:30:53
1078	2005-05-31 10:28:33	3682	230	2005-06-03 14:45:33	2	2006-02-15 21:30:53
1079	2005-05-31 10:48:17	268	312	2005-06-08 12:30:17	1	2006-02-15 21:30:53
1080	2005-05-31 10:55:26	3491	215	2005-06-03 13:13:26	2	2006-02-15 21:30:53
1081	2005-05-31 10:56:32	4524	404	2005-06-06 11:31:32	1	2006-02-15 21:30:53
1082	2005-05-31 11:02:01	4510	239	2005-06-05 08:43:01	1	2006-02-15 21:30:53
1083	2005-05-31 11:04:48	2393	556	2005-06-05 13:32:48	1	2006-02-15 21:30:53
1084	2005-05-31 11:10:17	4577	12	2005-06-01 11:15:17	1	2006-02-15 21:30:53
1085	2005-05-31 11:15:43	301	5	2005-06-07 12:02:43	1	2006-02-15 21:30:53
1086	2005-05-31 11:17:37	2909	549	2005-06-06 13:58:37	2	2006-02-15 21:30:53
1087	2005-05-31 11:18:08	431	169	2005-06-04 08:33:08	1	2006-02-15 21:30:53
1088	2005-05-31 11:35:13	3988	356	2005-06-06 16:01:13	2	2006-02-15 21:30:53
1089	2005-05-31 11:38:29	3784	367	2005-06-02 08:06:29	1	2006-02-15 21:30:53
1090	2005-05-31 12:03:44	3329	23	2005-06-02 15:54:44	2	2006-02-15 21:30:53
1091	2005-05-31 12:11:04	3853	251	2005-06-04 11:42:04	1	2006-02-15 21:30:53
1092	2005-05-31 12:15:57	4412	278	2005-06-03 15:39:57	2	2006-02-15 21:30:53
1093	2005-05-31 12:32:26	2189	214	2005-06-03 07:51:26	2	2006-02-15 21:30:53
1094	2005-05-31 13:03:49	3810	547	2005-06-05 14:30:49	2	2006-02-15 21:30:53
1095	2005-05-31 13:15:41	4546	252	2005-06-05 12:10:41	1	2006-02-15 21:30:53
1096	2005-05-31 13:30:49	1066	271	2005-06-09 13:53:49	1	2006-02-15 21:30:53
1097	2005-05-31 13:38:42	2285	491	2005-06-01 13:54:42	2	2006-02-15 21:30:53
1098	2005-05-31 13:51:48	1050	425	2005-06-09 18:42:48	2	2006-02-15 21:30:53
1099	2005-05-31 13:54:48	924	269	2005-06-05 13:04:48	2	2006-02-15 21:30:53
1100	2005-05-31 14:03:21	316	497	2005-06-06 16:08:21	1	2006-02-15 21:30:53
1101	2005-05-31 14:13:59	1174	260	2005-06-07 15:49:59	1	2006-02-15 21:30:53
1102	2005-05-31 14:20:29	2052	115	2005-06-04 17:38:29	2	2006-02-15 21:30:53
1103	2005-05-31 14:24:18	3154	353	2005-06-09 10:27:18	1	2006-02-15 21:30:53
1104	2005-05-31 14:30:01	1619	466	2005-06-05 12:07:01	1	2006-02-15 21:30:53
1105	2005-05-31 14:33:56	1708	26	2005-06-07 11:30:56	1	2006-02-15 21:30:53
1106	2005-05-31 14:36:52	4185	109	2005-06-01 14:33:52	2	2006-02-15 21:30:53
1107	2005-05-31 15:04:05	3449	53	2005-06-07 16:42:05	2	2006-02-15 21:30:53
1108	2005-05-31 15:05:12	2562	254	2005-06-09 19:48:12	2	2006-02-15 21:30:53
1109	2005-05-31 15:12:15	2031	481	2005-06-09 16:21:15	1	2006-02-15 21:30:53
1110	2005-05-31 15:22:51	2085	355	2005-06-07 14:32:51	1	2006-02-15 21:30:53
1111	2005-05-31 15:24:19	1137	300	2005-06-08 21:18:19	1	2006-02-15 21:30:53
1112	2005-05-31 15:51:39	2453	214	2005-06-03 14:04:39	1	2006-02-15 21:30:53
1113	2005-05-31 15:58:44	2078	451	2005-06-05 18:05:44	2	2006-02-15 21:30:53
1114	2005-05-31 16:00:33	2287	117	2005-06-01 19:05:33	1	2006-02-15 21:30:53
1115	2005-05-31 16:07:09	2140	109	2005-06-04 18:51:09	1	2006-02-15 21:30:53
1116	2005-05-31 16:10:46	1356	256	2005-06-01 20:27:46	2	2006-02-15 21:30:53
1117	2005-05-31 16:15:31	4125	189	2005-06-04 17:20:31	1	2006-02-15 21:30:53
1118	2005-05-31 16:23:02	213	510	2005-06-03 20:00:02	1	2006-02-15 21:30:53
1119	2005-05-31 16:34:27	4401	469	2005-06-02 10:54:27	1	2006-02-15 21:30:53
1120	2005-05-31 16:37:14	2897	361	2005-06-04 12:53:14	1	2006-02-15 21:30:53
1121	2005-05-31 16:37:36	1691	74	2005-06-06 21:02:36	1	2006-02-15 21:30:53
1122	2005-05-31 16:39:33	1392	180	2005-06-04 17:25:33	1	2006-02-15 21:30:53
1123	2005-05-31 16:48:43	142	448	2005-06-02 19:17:43	2	2006-02-15 21:30:53
1124	2005-05-31 16:49:34	4560	134	2005-06-04 19:32:34	2	2006-02-15 21:30:53
1125	2005-05-31 17:23:44	1172	234	2005-06-01 15:02:44	1	2006-02-15 21:30:53
1126	2005-05-31 17:27:45	2765	431	2005-06-04 20:06:45	2	2006-02-15 21:30:53
1127	2005-05-31 17:45:49	2412	387	2005-06-08 22:41:49	2	2006-02-15 21:30:53
1128	2005-05-31 17:49:26	1496	311	2005-06-05 19:51:26	2	2006-02-15 21:30:53
1129	2005-05-31 18:00:48	386	486	2005-06-04 23:05:48	1	2006-02-15 21:30:53
1130	2005-05-31 18:13:57	3186	124	2005-06-06 22:50:57	2	2006-02-15 21:30:53
1131	2005-05-31 18:44:19	2654	128	2005-06-01 20:13:19	1	2006-02-15 21:30:53
1132	2005-05-31 18:44:53	1763	198	2005-06-07 22:02:53	2	2006-02-15 21:30:53
1133	2005-05-31 19:12:21	4271	73	2005-06-02 20:12:21	1	2006-02-15 21:30:53
1134	2005-05-31 19:14:15	143	191	2005-06-02 17:13:15	2	2006-02-15 21:30:53
1135	2005-05-31 19:15:11	3118	122	2005-06-01 14:44:11	2	2006-02-15 21:30:53
1136	2005-05-31 19:19:36	3963	50	2005-06-09 16:04:36	2	2006-02-15 21:30:53
1137	2005-05-31 19:20:14	3259	351	2005-06-07 16:10:14	1	2006-02-15 21:30:53
1138	2005-05-31 19:30:27	3944	438	2005-06-05 21:42:27	1	2006-02-15 21:30:53
1139	2005-05-31 19:34:52	666	562	2005-06-06 17:40:52	1	2006-02-15 21:30:53
1140	2005-05-31 19:36:30	3731	10	2005-06-07 18:33:30	2	2006-02-15 21:30:53
1141	2005-05-31 19:42:02	4128	217	2005-06-07 00:59:02	2	2006-02-15 21:30:53
1142	2005-05-31 19:46:38	3998	5	2005-06-05 14:03:38	1	2006-02-15 21:30:53
1143	2005-05-31 19:53:03	2632	209	2005-06-06 20:56:03	2	2006-02-15 21:30:53
1144	2005-05-31 20:04:10	2450	207	2005-06-09 16:34:10	1	2006-02-15 21:30:53
1145	2005-05-31 20:13:45	1133	284	2005-06-08 02:10:45	1	2006-02-15 21:30:53
1146	2005-05-31 20:34:45	3134	250	2005-06-03 18:12:45	2	2006-02-15 21:30:53
1147	2005-05-31 20:37:52	622	259	2005-06-06 19:23:52	2	2006-02-15 21:30:53
1148	2005-05-31 20:38:40	3307	235	2005-06-02 18:35:40	2	2006-02-15 21:30:53
1149	2005-05-31 21:03:17	352	326	2005-06-08 19:58:17	2	2006-02-15 21:30:53
1150	2005-05-31 21:20:09	1632	136	2005-06-03 19:15:09	2	2006-02-15 21:30:53
1151	2005-05-31 21:29:00	1281	581	2005-06-03 23:24:00	1	2006-02-15 21:30:53
1152	2005-05-31 21:32:17	210	191	2005-06-04 21:07:17	2	2006-02-15 21:30:53
1153	2005-05-31 21:36:44	2725	506	2005-06-10 01:26:44	2	2006-02-15 21:30:53
1154	2005-05-31 21:42:09	2732	59	2005-06-08 16:40:09	1	2006-02-15 21:30:53
1155	2005-05-31 22:17:11	2048	251	2005-06-04 20:27:11	2	2006-02-15 21:30:53
1156	2005-05-31 22:37:34	460	106	2005-06-01 23:02:34	2	2006-02-15 21:30:53
1157	2005-05-31 22:47:45	1449	61	2005-06-02 18:01:45	1	2006-02-15 21:30:53
1158	2005-06-14 22:53:33	1632	416	2005-06-18 21:37:33	2	2006-02-15 21:30:53
1159	2005-06-14 22:55:13	4395	516	2005-06-17 02:11:13	1	2006-02-15 21:30:53
1160	2005-06-14 23:00:34	2795	239	2005-06-18 01:58:34	2	2006-02-15 21:30:53
1161	2005-06-14 23:07:08	1690	285	2005-06-21 17:12:08	1	2006-02-15 21:30:53
1162	2005-06-14 23:09:38	987	310	2005-06-23 22:00:38	1	2006-02-15 21:30:53
1163	2005-06-14 23:12:46	4209	592	2005-06-23 21:53:46	1	2006-02-15 21:30:53
1164	2005-06-14 23:16:26	3691	49	2005-06-16 21:00:26	1	2006-02-15 21:30:53
1165	2005-06-14 23:16:27	2855	264	2005-06-20 02:40:27	2	2006-02-15 21:30:53
1166	2005-06-14 23:17:03	2508	46	2005-06-15 20:43:03	1	2006-02-15 21:30:53
1167	2005-06-14 23:25:58	4021	323	2005-06-18 05:18:58	2	2006-02-15 21:30:53
1168	2005-06-14 23:35:09	4368	481	2005-06-19 03:20:09	1	2006-02-15 21:30:53
1169	2005-06-14 23:42:56	1062	139	2005-06-16 04:02:56	2	2006-02-15 21:30:53
1170	2005-06-14 23:47:35	2444	595	2005-06-17 05:28:35	2	2006-02-15 21:30:53
1171	2005-06-14 23:50:11	4082	284	2005-06-17 21:44:11	2	2006-02-15 21:30:53
1172	2005-06-14 23:54:34	2685	306	2005-06-16 02:26:34	1	2006-02-15 21:30:53
1173	2005-06-14 23:54:46	1050	191	2005-06-19 23:26:46	2	2006-02-15 21:30:53
1174	2005-06-15 00:12:51	2653	95	2005-06-21 02:10:51	2	2006-02-15 21:30:53
1175	2005-06-15 00:15:15	3255	197	2005-06-20 19:23:15	2	2006-02-15 21:30:53
1176	2005-06-15 00:28:37	2715	512	2005-06-21 21:42:37	1	2006-02-15 21:30:53
1177	2005-06-15 00:33:04	1897	210	2005-06-16 03:47:04	2	2006-02-15 21:30:53
1178	2005-06-15 00:36:40	2553	279	2005-06-21 00:27:40	2	2006-02-15 21:30:53
1179	2005-06-15 00:36:50	816	119	2005-06-22 22:09:50	1	2006-02-15 21:30:53
1180	2005-06-15 00:39:01	3119	432	2005-06-21 22:44:01	2	2006-02-15 21:30:53
1181	2005-06-15 00:42:17	2973	546	2005-06-19 03:36:17	2	2006-02-15 21:30:53
1182	2005-06-15 00:45:21	1061	196	2005-06-22 03:52:21	1	2006-02-15 21:30:53
1183	2005-06-15 00:49:19	706	329	2005-06-20 04:33:19	1	2006-02-15 21:30:53
1184	2005-06-15 00:49:36	473	295	2005-06-22 23:39:36	2	2006-02-15 21:30:53
1185	2005-06-15 00:54:12	2785	1	2005-06-23 02:42:12	2	2006-02-15 21:30:53
1186	2005-06-15 00:56:45	1556	368	2005-06-16 02:23:45	1	2006-02-15 21:30:53
1187	2005-06-15 00:58:50	1108	334	2005-06-23 02:19:50	1	2006-02-15 21:30:53
1188	2005-06-15 01:04:07	246	173	2005-06-19 03:48:07	1	2006-02-15 21:30:53
1189	2005-06-15 01:04:22	142	244	2005-06-24 06:48:22	1	2006-02-15 21:30:53
1190	2005-06-15 01:05:32	2572	370	2005-06-23 02:34:32	2	2006-02-15 21:30:53
1191	2005-06-15 01:10:35	2221	291	2005-06-17 20:36:35	2	2006-02-15 21:30:53
1192	2005-06-15 01:18:39	4134	186	2005-06-19 22:46:39	1	2006-02-15 21:30:53
1193	2005-06-15 01:24:20	4504	561	2005-06-21 02:29:20	2	2006-02-15 21:30:53
1194	2005-06-15 01:25:08	3774	402	2005-06-21 01:16:08	2	2006-02-15 21:30:53
1195	2005-06-15 01:37:38	2272	84	2005-06-17 21:50:38	1	2006-02-15 21:30:53
1196	2005-06-15 01:38:31	994	52	2005-06-18 06:55:31	1	2006-02-15 21:30:53
1197	2005-06-15 01:42:46	3812	349	2005-06-20 00:22:46	1	2006-02-15 21:30:53
1198	2005-06-15 01:48:58	1138	491	2005-06-20 01:07:58	2	2006-02-15 21:30:53
1199	2005-06-15 01:58:50	253	238	2005-06-16 20:30:50	2	2006-02-15 21:30:53
1200	2005-06-15 01:59:51	3329	516	2005-06-21 21:33:51	1	2006-02-15 21:30:53
1201	2005-06-15 02:06:28	2679	209	2005-06-16 21:38:28	2	2006-02-15 21:30:53
1202	2005-06-15 02:08:04	2821	451	2005-06-16 21:56:04	1	2006-02-15 21:30:53
1203	2005-06-15 02:09:02	2223	452	2005-06-21 00:04:02	1	2006-02-15 21:30:53
1204	2005-06-15 02:21:46	2450	249	2005-06-20 07:14:46	2	2006-02-15 21:30:53
1205	2005-06-15 02:25:56	470	340	2005-06-22 23:19:56	1	2006-02-15 21:30:53
1206	2005-06-15 02:27:07	1097	264	2005-06-18 22:46:07	2	2006-02-15 21:30:53
1207	2005-06-15 02:27:08	2277	430	2005-06-19 08:18:08	2	2006-02-15 21:30:53
1208	2005-06-15 02:30:03	750	376	2005-06-18 00:04:03	1	2006-02-15 21:30:53
1209	2005-06-15 02:31:12	1494	146	2005-06-21 07:39:12	1	2006-02-15 21:30:53
1210	2005-06-15 02:57:51	7	345	2005-06-20 01:41:51	2	2006-02-15 21:30:53
1211	2005-06-15 03:01:20	3360	122	2005-06-18 07:52:20	2	2006-02-15 21:30:53
1212	2005-06-15 03:03:33	3611	371	2005-06-17 06:31:33	1	2006-02-15 21:30:53
1213	2005-06-15 03:14:05	3191	94	2005-06-15 21:41:05	2	2006-02-15 21:30:53
1214	2005-06-15 03:18:40	4482	46	2005-06-20 07:32:40	1	2006-02-15 21:30:53
1215	2005-06-15 03:21:00	242	102	2005-06-19 03:39:00	1	2006-02-15 21:30:53
1216	2005-06-15 03:23:48	3973	100	2005-06-18 03:35:48	1	2006-02-15 21:30:53
1217	2005-06-15 03:24:14	600	203	2005-06-18 22:37:14	2	2006-02-15 21:30:53
1218	2005-06-15 03:24:44	239	371	2005-06-21 22:45:44	2	2006-02-15 21:30:53
1219	2005-06-15 03:25:59	3005	330	2005-06-20 00:37:59	1	2006-02-15 21:30:53
1220	2005-06-15 03:26:15	1621	290	2005-06-23 08:17:15	1	2006-02-15 21:30:53
1221	2005-06-15 03:35:16	2124	403	2005-06-18 03:11:16	1	2006-02-15 21:30:53
1222	2005-06-15 03:38:49	2799	168	2005-06-17 22:30:49	1	2006-02-15 21:30:53
1223	2005-06-15 03:38:53	1299	50	2005-06-20 01:00:53	2	2006-02-15 21:30:53
1224	2005-06-15 03:44:25	1572	369	2005-06-17 03:49:25	2	2006-02-15 21:30:53
1225	2005-06-15 03:45:35	1929	434	2005-06-19 02:03:35	1	2006-02-15 21:30:53
1226	2005-06-15 03:46:10	2290	409	2005-06-23 02:00:10	1	2006-02-15 21:30:53
1227	2005-06-15 03:50:03	654	428	2005-06-21 23:48:03	2	2006-02-15 21:30:53
1228	2005-06-15 03:50:36	4473	398	2005-06-17 22:41:36	1	2006-02-15 21:30:53
1229	2005-06-15 03:53:13	2140	468	2005-06-18 04:09:13	1	2006-02-15 21:30:53
1230	2005-06-15 04:04:09	2324	447	2005-06-16 02:21:09	1	2006-02-15 21:30:53
1231	2005-06-15 04:04:41	3003	302	2005-06-20 23:52:41	2	2006-02-15 21:30:53
1232	2005-06-15 04:18:10	2743	391	2005-06-17 06:02:10	2	2006-02-15 21:30:53
1233	2005-06-15 04:18:37	4214	550	2005-06-22 03:36:37	1	2006-02-15 21:30:53
1234	2005-06-15 04:21:52	709	529	2005-06-22 03:25:52	1	2006-02-15 21:30:53
1235	2005-06-15 04:31:28	1000	255	2005-06-22 10:08:28	1	2006-02-15 21:30:53
1236	2005-06-15 04:34:27	3182	66	2005-06-18 08:15:27	1	2006-02-15 21:30:53
1237	2005-06-15 04:44:10	3249	49	2005-06-23 07:00:10	2	2006-02-15 21:30:53
1238	2005-06-15 04:49:08	3534	205	2005-06-20 00:06:08	1	2006-02-15 21:30:53
1239	2005-06-15 04:53:01	3731	444	2005-06-16 07:03:01	1	2006-02-15 21:30:53
1240	2005-06-15 04:58:07	3841	28	2005-06-17 23:56:07	1	2006-02-15 21:30:53
1241	2005-06-15 04:59:43	4377	62	2005-06-24 03:32:43	2	2006-02-15 21:30:53
1242	2005-06-15 05:05:07	821	141	2005-06-22 04:57:07	1	2006-02-15 21:30:53
1243	2005-06-15 05:07:32	2629	107	2005-06-21 08:17:32	2	2006-02-15 21:30:53
1244	2005-06-15 05:08:40	1026	515	2005-06-20 10:41:40	1	2006-02-15 21:30:53
1245	2005-06-15 05:09:01	1314	234	2005-06-22 06:55:01	2	2006-02-15 21:30:53
1246	2005-06-15 05:11:19	431	357	2005-06-21 02:21:19	1	2006-02-15 21:30:53
1247	2005-06-15 05:16:40	4049	287	2005-06-23 11:01:40	1	2006-02-15 21:30:53
1248	2005-06-15 05:33:52	3878	544	2005-06-19 06:56:52	2	2006-02-15 21:30:53
1249	2005-06-15 05:38:09	2120	403	2005-06-22 10:29:09	1	2006-02-15 21:30:53
1250	2005-06-15 05:55:40	4360	38	2005-06-23 03:11:40	2	2006-02-15 21:30:53
1251	2005-06-15 05:58:55	3307	442	2005-06-23 02:45:55	2	2006-02-15 21:30:53
1252	2005-06-15 06:05:18	1147	89	2005-06-24 07:40:18	1	2006-02-15 21:30:53
1253	2005-06-15 06:06:33	3242	498	2005-06-21 04:13:33	2	2006-02-15 21:30:53
1254	2005-06-15 06:11:16	3986	571	2005-06-21 06:40:16	2	2006-02-15 21:30:53
1255	2005-06-15 06:13:45	1433	526	2005-06-16 03:59:45	2	2006-02-15 21:30:53
1256	2005-06-15 06:13:57	1437	470	2005-06-16 06:54:57	2	2006-02-15 21:30:53
1257	2005-06-15 06:15:36	1938	267	2005-06-21 01:04:36	2	2006-02-15 21:30:53
1258	2005-06-15 06:21:30	4530	320	2005-06-18 05:43:30	2	2006-02-15 21:30:53
1259	2005-06-15 06:37:55	4460	570	2005-06-23 04:02:55	2	2006-02-15 21:30:53
1260	2005-06-15 06:42:25	330	586	2005-06-16 10:44:25	2	2006-02-15 21:30:53
1261	2005-06-15 06:52:57	2447	95	2005-06-21 01:47:57	2	2006-02-15 21:30:53
1262	2005-06-15 06:54:53	4495	236	2005-06-22 08:09:53	2	2006-02-15 21:30:53
1263	2005-06-15 06:56:39	4144	540	2005-06-16 11:08:39	1	2006-02-15 21:30:53
1264	2005-06-15 06:59:39	4176	439	2005-06-18 08:10:39	2	2006-02-15 21:30:53
1265	2005-06-15 07:00:50	982	163	2005-06-19 12:27:50	1	2006-02-15 21:30:53
1266	2005-06-15 07:11:39	2230	96	2005-06-21 02:59:39	2	2006-02-15 21:30:53
1267	2005-06-15 07:21:21	4246	509	2005-06-17 08:12:21	2	2006-02-15 21:30:53
1268	2005-06-15 07:29:30	3641	142	2005-06-23 12:36:30	1	2006-02-15 21:30:53
1269	2005-06-15 07:29:59	108	59	2005-06-16 13:26:59	2	2006-02-15 21:30:53
1270	2005-06-15 07:30:22	62	395	2005-06-18 11:31:22	2	2006-02-15 21:30:53
1271	2005-06-15 07:32:24	379	560	2005-06-21 05:12:24	1	2006-02-15 21:30:53
1272	2005-06-15 07:42:58	3128	135	2005-06-18 12:00:58	1	2006-02-15 21:30:53
1273	2005-06-15 07:52:35	361	530	2005-06-21 04:55:35	1	2006-02-15 21:30:53
1274	2005-06-15 07:52:52	2765	430	2005-06-20 10:01:52	1	2006-02-15 21:30:53
1275	2005-06-15 07:55:43	950	214	2005-06-20 06:30:43	1	2006-02-15 21:30:53
1276	2005-06-15 08:00:13	1508	388	2005-06-24 02:55:13	2	2006-02-15 21:30:53
1277	2005-06-15 08:01:29	76	464	2005-06-22 07:16:29	2	2006-02-15 21:30:53
1278	2005-06-15 08:09:12	4471	191	2005-06-17 04:05:12	2	2006-02-15 21:30:53
1279	2005-06-15 08:13:57	698	183	2005-06-18 09:36:57	2	2006-02-15 21:30:53
1280	2005-06-15 08:16:06	2597	266	2005-06-21 04:10:06	2	2006-02-15 21:30:53
1281	2005-06-15 08:21:39	2963	511	2005-06-17 11:03:39	1	2006-02-15 21:30:53
1282	2005-06-15 08:25:33	186	539	2005-06-21 04:02:33	1	2006-02-15 21:30:53
1283	2005-06-15 08:27:30	3177	470	2005-06-16 09:46:30	2	2006-02-15 21:30:53
1284	2005-06-15 08:27:33	1387	463	2005-06-17 03:58:33	1	2006-02-15 21:30:53
1285	2005-06-15 08:33:06	1054	254	2005-06-19 07:36:06	1	2006-02-15 21:30:53
1286	2005-06-15 08:41:13	774	179	2005-06-23 13:13:13	2	2006-02-15 21:30:53
1287	2005-06-15 08:41:38	4204	104	2005-06-22 14:02:38	1	2006-02-15 21:30:53
1288	2005-06-15 08:41:52	830	456	2005-06-19 05:30:52	2	2006-02-15 21:30:53
1289	2005-06-15 08:44:09	3154	522	2005-06-21 06:04:09	1	2006-02-15 21:30:53
1290	2005-06-15 08:52:44	1921	540	2005-06-24 13:36:44	2	2006-02-15 21:30:53
1291	2005-06-15 08:55:01	3090	176	2005-06-24 04:22:01	1	2006-02-15 21:30:53
1292	2005-06-15 09:03:52	4535	178	2005-06-21 07:53:52	1	2006-02-15 21:30:53
1293	2005-06-15 09:06:24	2882	127	2005-06-18 06:58:24	1	2006-02-15 21:30:53
1294	2005-06-15 09:09:27	339	327	2005-06-19 04:43:27	1	2006-02-15 21:30:53
1295	2005-06-15 09:17:20	2897	449	2005-06-18 10:14:20	2	2006-02-15 21:30:53
1296	2005-06-15 09:23:59	1760	200	2005-06-19 03:44:59	2	2006-02-15 21:30:53
1297	2005-06-15 09:31:28	1075	4	2005-06-19 04:33:28	1	2006-02-15 21:30:53
1298	2005-06-15 09:32:53	4163	334	2005-06-16 12:40:53	2	2006-02-15 21:30:53
1299	2005-06-15 09:34:50	1584	91	2005-06-21 12:07:50	1	2006-02-15 21:30:53
1300	2005-06-15 09:36:19	2524	186	2005-06-17 13:54:19	2	2006-02-15 21:30:53
1301	2005-06-15 09:46:33	1484	33	2005-06-24 08:56:33	2	2006-02-15 21:30:53
1302	2005-06-15 09:48:37	324	285	2005-06-22 06:18:37	1	2006-02-15 21:30:53
1303	2005-06-15 09:55:57	2001	365	2005-06-20 14:26:57	2	2006-02-15 21:30:53
1304	2005-06-15 09:56:02	1304	242	2005-06-24 07:00:02	1	2006-02-15 21:30:53
1305	2005-06-15 09:59:16	187	8	2005-06-19 09:48:16	2	2006-02-15 21:30:53
1306	2005-06-15 09:59:24	2132	524	2005-06-19 09:37:24	2	2006-02-15 21:30:53
1307	2005-06-15 10:06:15	368	507	2005-06-20 04:50:15	2	2006-02-15 21:30:53
1308	2005-06-15 10:07:48	220	236	2005-06-24 15:24:48	1	2006-02-15 21:30:53
1309	2005-06-15 10:10:49	2356	200	2005-06-16 12:44:49	1	2006-02-15 21:30:53
1310	2005-06-15 10:11:42	2045	27	2005-06-16 15:00:42	1	2006-02-15 21:30:53
1311	2005-06-15 10:11:59	3114	326	2005-06-17 08:44:59	2	2006-02-15 21:30:53
1312	2005-06-15 10:16:27	3608	313	2005-06-20 06:53:27	1	2006-02-15 21:30:53
1313	2005-06-15 10:18:34	1657	448	2005-06-23 06:25:34	1	2006-02-15 21:30:53
1314	2005-06-15 10:21:45	1359	538	2005-06-21 14:10:45	1	2006-02-15 21:30:53
1315	2005-06-15 10:23:08	3844	405	2005-06-21 15:06:08	1	2006-02-15 21:30:53
1316	2005-06-15 10:26:23	3891	138	2005-06-21 09:25:23	2	2006-02-15 21:30:53
1317	2005-06-15 10:30:19	3696	316	2005-06-24 08:18:19	1	2006-02-15 21:30:53
1318	2005-06-15 10:34:26	2760	341	2005-06-20 16:20:26	1	2006-02-15 21:30:53
1319	2005-06-15 10:39:05	4296	190	2005-06-18 05:25:05	1	2006-02-15 21:30:53
1320	2005-06-15 10:42:13	4484	84	2005-06-17 13:44:13	1	2006-02-15 21:30:53
1321	2005-06-15 10:49:17	3516	204	2005-06-16 15:30:17	1	2006-02-15 21:30:53
1322	2005-06-15 10:55:09	2076	217	2005-06-18 15:14:09	2	2006-02-15 21:30:53
1323	2005-06-15 10:55:17	3273	187	2005-06-24 09:51:17	1	2006-02-15 21:30:53
1324	2005-06-15 11:02:45	764	394	2005-06-17 07:14:45	1	2006-02-15 21:30:53
1325	2005-06-15 11:03:24	52	193	2005-06-20 10:54:24	1	2006-02-15 21:30:53
1326	2005-06-15 11:07:39	59	548	2005-06-22 05:55:39	2	2006-02-15 21:30:53
1327	2005-06-15 11:11:39	403	539	2005-06-22 10:45:39	1	2006-02-15 21:30:53
1328	2005-06-15 11:23:27	3665	295	2005-06-19 12:42:27	2	2006-02-15 21:30:53
1329	2005-06-15 11:25:06	1154	359	2005-06-17 16:10:06	2	2006-02-15 21:30:53
1330	2005-06-15 11:29:17	1219	587	2005-06-24 13:36:17	2	2006-02-15 21:30:53
1331	2005-06-15 11:34:33	3089	277	2005-06-21 09:46:33	1	2006-02-15 21:30:53
1332	2005-06-15 11:36:01	1412	116	2005-06-17 14:29:01	1	2006-02-15 21:30:53
1333	2005-06-15 11:37:08	448	310	2005-06-16 10:13:08	2	2006-02-15 21:30:53
1334	2005-06-15 11:43:09	1242	269	2005-06-20 15:45:09	2	2006-02-15 21:30:53
1335	2005-06-15 11:51:30	1713	64	2005-06-16 16:42:30	2	2006-02-15 21:30:53
1336	2005-06-15 12:01:34	1696	290	2005-06-23 12:05:34	1	2006-02-15 21:30:53
1337	2005-06-15 12:12:42	4014	465	2005-06-20 12:38:42	2	2006-02-15 21:30:53
1338	2005-06-15 12:17:34	1206	25	2005-06-19 07:40:34	2	2006-02-15 21:30:53
1339	2005-06-15 12:21:56	424	162	2005-06-19 07:46:56	1	2006-02-15 21:30:53
1340	2005-06-15 12:24:15	251	100	2005-06-22 13:02:15	1	2006-02-15 21:30:53
1341	2005-06-15 12:26:18	3363	344	2005-06-21 07:26:18	2	2006-02-15 21:30:53
1342	2005-06-15 12:26:21	4429	427	2005-06-22 11:23:21	1	2006-02-15 21:30:53
1343	2005-06-15 12:27:19	2393	416	2005-06-21 16:57:19	1	2006-02-15 21:30:53
1344	2005-06-15 12:29:41	1625	585	2005-06-22 12:45:41	2	2006-02-15 21:30:53
1345	2005-06-15 12:32:13	1041	270	2005-06-24 14:02:13	1	2006-02-15 21:30:53
1346	2005-06-15 12:39:52	4540	585	2005-06-24 17:43:52	1	2006-02-15 21:30:53
1347	2005-06-15 12:43:43	374	190	2005-06-16 09:55:43	1	2006-02-15 21:30:53
1348	2005-06-15 12:45:30	2078	196	2005-06-17 17:12:30	1	2006-02-15 21:30:53
1349	2005-06-15 12:49:02	1131	267	2005-06-17 15:20:02	1	2006-02-15 21:30:53
1350	2005-06-15 12:50:25	4261	316	2005-06-23 11:35:25	1	2006-02-15 21:30:53
1351	2005-06-15 12:51:03	2364	484	2005-06-22 07:23:03	1	2006-02-15 21:30:53
1352	2005-06-15 12:58:27	4352	276	2005-06-18 10:57:27	1	2006-02-15 21:30:53
1353	2005-06-15 13:13:36	2711	480	2005-06-21 08:46:36	2	2006-02-15 21:30:53
1354	2005-06-15 13:13:49	1294	83	2005-06-23 13:08:49	2	2006-02-15 21:30:53
1355	2005-06-15 13:13:59	4203	499	2005-06-20 12:23:59	1	2006-02-15 21:30:53
1356	2005-06-15 13:17:01	1318	212	2005-06-19 16:22:01	1	2006-02-15 21:30:53
1357	2005-06-15 13:26:23	2285	205	2005-06-23 14:12:23	1	2006-02-15 21:30:53
1358	2005-06-15 13:28:48	2025	442	2005-06-21 13:40:48	1	2006-02-15 21:30:53
1359	2005-06-15 13:30:30	3140	353	2005-06-17 14:55:30	1	2006-02-15 21:30:53
1360	2005-06-15 13:32:15	4107	14	2005-06-18 10:59:15	2	2006-02-15 21:30:53
1361	2005-06-15 13:37:38	4338	115	2005-06-19 17:08:38	1	2006-02-15 21:30:53
1362	2005-06-15 13:53:32	4524	98	2005-06-19 16:05:32	1	2006-02-15 21:30:53
1363	2005-06-15 14:05:11	771	197	2005-06-17 19:53:11	2	2006-02-15 21:30:53
1364	2005-06-15 14:05:32	115	400	2005-06-16 15:31:32	1	2006-02-15 21:30:53
1365	2005-06-15 14:09:55	3813	25	2005-06-19 18:11:55	2	2006-02-15 21:30:53
1366	2005-06-15 14:21:00	4238	576	2005-06-24 17:36:00	1	2006-02-15 21:30:53
1367	2005-06-15 14:25:17	1505	94	2005-06-21 19:15:17	1	2006-02-15 21:30:53
1368	2005-06-15 14:27:47	2020	222	2005-06-23 18:07:47	2	2006-02-15 21:30:53
1369	2005-06-15 14:29:14	679	221	2005-06-16 13:01:14	1	2006-02-15 21:30:53
1370	2005-06-15 14:31:05	644	396	2005-06-22 19:23:05	2	2006-02-15 21:30:53
1371	2005-06-15 14:38:15	760	491	2005-06-23 15:36:15	1	2006-02-15 21:30:53
1372	2005-06-15 14:45:48	3740	108	2005-06-17 18:02:48	2	2006-02-15 21:30:53
1373	2005-06-15 14:48:04	284	51	2005-06-22 09:48:04	1	2006-02-15 21:30:53
1374	2005-06-15 14:49:54	3353	120	2005-06-22 12:30:54	1	2006-02-15 21:30:53
1375	2005-06-15 14:54:56	3555	500	2005-06-21 14:48:56	2	2006-02-15 21:30:53
1376	2005-06-15 14:59:06	4271	215	2005-06-19 17:34:06	1	2006-02-15 21:30:53
1377	2005-06-15 15:02:03	3410	245	2005-06-22 14:54:03	2	2006-02-15 21:30:53
1378	2005-06-15 15:03:15	4372	253	2005-06-19 16:50:15	1	2006-02-15 21:30:53
1379	2005-06-15 15:05:10	810	212	2005-06-18 12:11:10	1	2006-02-15 21:30:53
1380	2005-06-15 15:13:10	3376	158	2005-06-18 12:42:10	2	2006-02-15 21:30:53
1381	2005-06-15 15:17:21	3262	300	2005-06-20 17:07:21	2	2006-02-15 21:30:53
1382	2005-06-15 15:18:08	3133	455	2005-06-22 09:22:08	2	2006-02-15 21:30:53
1383	2005-06-15 15:20:06	1281	379	2005-06-24 18:42:06	2	2006-02-15 21:30:53
1384	2005-06-15 15:22:03	4242	242	2005-06-18 18:11:03	1	2006-02-15 21:30:53
1385	2005-06-15 15:28:23	4073	396	2005-06-18 18:37:23	1	2006-02-15 21:30:53
1386	2005-06-15 15:38:58	1296	322	2005-06-20 16:28:58	2	2006-02-15 21:30:53
1387	2005-06-15 15:40:56	515	278	2005-06-17 10:39:56	1	2006-02-15 21:30:53
1388	2005-06-15 15:48:41	3987	500	2005-06-22 17:51:41	1	2006-02-15 21:30:53
1389	2005-06-15 15:49:01	965	472	2005-06-19 11:08:01	2	2006-02-15 21:30:53
1390	2005-06-15 16:06:29	4502	254	2005-06-19 13:11:29	1	2006-02-15 21:30:53
1391	2005-06-15 16:11:21	4213	273	2005-06-22 21:32:21	1	2006-02-15 21:30:53
1392	2005-06-15 16:12:27	363	460	2005-06-16 17:30:27	2	2006-02-15 21:30:53
1393	2005-06-15 16:12:50	2767	177	2005-06-19 10:40:50	2	2006-02-15 21:30:53
1394	2005-06-15 16:17:21	2802	268	2005-06-21 20:44:21	2	2006-02-15 21:30:53
1395	2005-06-15 16:21:04	753	252	2005-06-23 12:52:04	2	2006-02-15 21:30:53
1396	2005-06-15 16:22:38	1007	103	2005-06-17 15:53:38	2	2006-02-15 21:30:53
1397	2005-06-15 16:25:26	1830	444	2005-06-21 20:45:26	1	2006-02-15 21:30:53
1398	2005-06-15 16:28:42	4402	527	2005-06-16 12:11:42	1	2006-02-15 21:30:53
1399	2005-06-15 16:29:51	1435	469	2005-06-18 14:06:51	1	2006-02-15 21:30:53
1400	2005-06-15 16:29:56	230	571	2005-06-21 14:43:56	2	2006-02-15 21:30:53
1401	2005-06-15 16:30:22	4081	366	2005-06-21 11:07:22	2	2006-02-15 21:30:53
1402	2005-06-15 16:31:08	1951	381	2005-06-24 19:31:08	1	2006-02-15 21:30:53
1403	2005-06-15 16:31:59	3380	546	2005-06-22 14:23:59	2	2006-02-15 21:30:53
1404	2005-06-15 16:38:53	2776	375	2005-06-16 20:37:53	1	2006-02-15 21:30:53
1405	2005-06-15 16:41:26	3184	243	2005-06-21 18:16:26	1	2006-02-15 21:30:53
1406	2005-06-15 16:44:00	3118	199	2005-06-21 11:22:00	2	2006-02-15 21:30:53
1407	2005-06-15 16:45:07	1286	89	2005-06-23 14:01:07	1	2006-02-15 21:30:53
1408	2005-06-15 16:57:58	2655	396	2005-06-22 21:08:58	1	2006-02-15 21:30:53
1409	2005-06-15 16:58:12	1398	297	2005-06-21 11:21:12	2	2006-02-15 21:30:53
1410	2005-06-15 16:59:46	809	356	2005-06-21 16:38:46	1	2006-02-15 21:30:53
1411	2005-06-15 17:05:36	2276	520	2005-06-21 14:05:36	1	2006-02-15 21:30:53
1412	2005-06-15 17:09:48	4236	166	2005-06-18 17:05:48	2	2006-02-15 21:30:53
1413	2005-06-15 17:25:07	3625	96	2005-06-21 17:17:07	2	2006-02-15 21:30:53
1414	2005-06-15 17:26:32	4005	304	2005-06-22 22:30:32	1	2006-02-15 21:30:53
1415	2005-06-15 17:31:57	1885	331	2005-06-16 22:22:57	2	2006-02-15 21:30:53
1416	2005-06-15 17:44:57	3816	167	2005-06-22 20:53:57	2	2006-02-15 21:30:53
1417	2005-06-15 17:45:51	1334	570	2005-06-19 14:00:51	2	2006-02-15 21:30:53
1418	2005-06-15 17:51:27	2974	591	2005-06-18 23:20:27	2	2006-02-15 21:30:53
1419	2005-06-15 17:54:50	1208	312	2005-06-17 19:44:50	2	2006-02-15 21:30:53
1420	2005-06-15 17:56:14	4149	255	2005-06-24 15:45:14	2	2006-02-15 21:30:53
1421	2005-06-15 17:57:04	2439	533	2005-06-21 20:38:04	2	2006-02-15 21:30:53
1422	2005-06-15 18:02:53	1021	1	2005-06-19 15:54:53	2	2006-02-15 21:30:53
1423	2005-06-15 18:08:12	1396	592	2005-06-24 19:13:12	1	2006-02-15 21:30:53
1424	2005-06-15 18:08:14	887	224	2005-06-24 23:16:14	2	2006-02-15 21:30:53
1425	2005-06-15 18:13:46	1308	108	2005-06-18 22:50:46	2	2006-02-15 21:30:53
1426	2005-06-15 18:16:24	4412	363	2005-06-18 22:15:24	2	2006-02-15 21:30:53
1427	2005-06-15 18:17:28	14	100	2005-06-16 15:47:28	1	2006-02-15 21:30:53
1428	2005-06-15 18:19:30	3689	583	2005-06-22 23:05:30	2	2006-02-15 21:30:53
1429	2005-06-15 18:24:10	4116	362	2005-06-18 16:30:10	1	2006-02-15 21:30:53
1430	2005-06-15 18:24:55	3412	194	2005-06-16 12:26:55	1	2006-02-15 21:30:53
1431	2005-06-15 18:26:29	3193	438	2005-06-21 17:33:29	1	2006-02-15 21:30:53
1432	2005-06-15 18:27:24	523	339	2005-06-21 14:03:24	2	2006-02-15 21:30:53
1433	2005-06-15 18:30:00	2310	88	2005-06-16 15:14:00	1	2006-02-15 21:30:53
1434	2005-06-15 18:30:46	4228	544	2005-06-24 17:51:46	1	2006-02-15 21:30:53
1435	2005-06-15 18:32:30	2769	510	2005-06-24 12:44:30	2	2006-02-15 21:30:53
1436	2005-06-15 18:35:40	924	584	2005-06-21 15:04:40	1	2006-02-15 21:30:53
1437	2005-06-15 18:37:04	3263	96	2005-06-20 12:56:04	1	2006-02-15 21:30:53
1438	2005-06-15 18:38:51	1816	82	2005-06-17 23:50:51	1	2006-02-15 21:30:53
1439	2005-06-15 18:45:32	3155	589	2005-06-22 15:57:32	2	2006-02-15 21:30:53
1440	2005-06-15 18:53:14	2921	26	2005-06-24 15:28:14	1	2006-02-15 21:30:53
1441	2005-06-15 18:54:21	2095	444	2005-06-22 22:48:21	2	2006-02-15 21:30:53
1442	2005-06-15 18:55:34	3912	122	2005-06-22 20:41:34	2	2006-02-15 21:30:53
1443	2005-06-15 18:57:51	2485	435	2005-06-18 14:18:51	2	2006-02-15 21:30:53
1444	2005-06-15 19:08:16	1303	539	2005-06-24 15:20:16	2	2006-02-15 21:30:53
1445	2005-06-15 19:10:07	3189	537	2005-06-19 20:27:07	2	2006-02-15 21:30:53
1446	2005-06-15 19:13:45	1989	506	2005-06-23 19:43:45	2	2006-02-15 21:30:53
1447	2005-06-15 19:13:51	984	471	2005-06-21 22:56:51	1	2006-02-15 21:30:53
1448	2005-06-15 19:17:16	2781	246	2005-06-23 21:56:16	2	2006-02-15 21:30:53
1449	2005-06-15 19:19:16	1525	471	2005-06-18 15:24:16	2	2006-02-15 21:30:53
1450	2005-06-15 19:22:08	4132	268	2005-06-16 17:53:08	2	2006-02-15 21:30:53
1451	2005-06-15 19:30:18	3560	18	2005-06-19 19:22:18	2	2006-02-15 21:30:53
1452	2005-06-15 19:32:52	4348	243	2005-06-16 13:45:52	1	2006-02-15 21:30:53
1453	2005-06-15 19:36:39	3274	457	2005-06-19 00:16:39	2	2006-02-15 21:30:53
1454	2005-06-15 19:49:41	102	298	2005-06-17 15:17:41	2	2006-02-15 21:30:53
1455	2005-06-15 19:51:06	2194	358	2005-06-18 21:54:06	2	2006-02-15 21:30:53
1456	2005-06-15 20:00:11	632	590	2005-06-23 18:03:11	2	2006-02-15 21:30:53
1457	2005-06-15 20:05:49	730	345	2005-06-19 15:35:49	1	2006-02-15 21:30:53
1458	2005-06-15 20:24:05	3546	178	2005-06-21 01:22:05	1	2006-02-15 21:30:53
1459	2005-06-15 20:25:53	1862	218	2005-06-22 23:34:53	2	2006-02-15 21:30:53
1460	2005-06-15 20:27:02	1405	565	2005-06-16 16:21:02	1	2006-02-15 21:30:53
1461	2005-06-15 20:32:08	4479	216	2005-06-23 01:08:08	1	2006-02-15 21:30:53
1462	2005-06-15 20:37:40	653	187	2005-06-18 19:36:40	2	2006-02-15 21:30:53
1463	2005-06-15 20:37:51	2984	569	2005-06-21 16:46:51	2	2006-02-15 21:30:53
1464	2005-06-15 20:38:14	4113	387	2005-06-17 14:52:14	2	2006-02-15 21:30:53
1465	2005-06-15 20:43:08	609	387	2005-06-18 23:00:08	1	2006-02-15 21:30:53
1466	2005-06-15 20:46:04	1057	288	2005-06-24 22:46:04	1	2006-02-15 21:30:53
1467	2005-06-15 20:47:10	688	506	2005-06-22 00:30:10	1	2006-02-15 21:30:53
1468	2005-06-15 20:48:22	228	230	2005-06-21 19:48:22	1	2006-02-15 21:30:53
1469	2005-06-15 20:52:36	2451	580	2005-06-21 19:55:36	1	2006-02-15 21:30:53
1470	2005-06-15 20:53:07	4044	11	2005-06-25 02:12:07	1	2006-02-15 21:30:53
1471	2005-06-15 20:53:26	565	428	2005-06-24 18:25:26	2	2006-02-15 21:30:53
1472	2005-06-15 20:54:55	4233	373	2005-06-24 21:52:55	2	2006-02-15 21:30:53
1473	2005-06-15 20:55:20	2377	249	2005-06-21 16:40:20	2	2006-02-15 21:30:53
1474	2005-06-15 20:55:42	164	202	2005-06-19 02:41:42	2	2006-02-15 21:30:53
1475	2005-06-15 21:08:01	1834	344	2005-06-18 22:33:01	2	2006-02-15 21:30:53
1476	2005-06-15 21:08:46	1407	1	2005-06-25 02:26:46	1	2006-02-15 21:30:53
1477	2005-06-15 21:11:18	418	51	2005-06-19 02:05:18	1	2006-02-15 21:30:53
1478	2005-06-15 21:12:13	435	336	2005-06-18 21:43:13	2	2006-02-15 21:30:53
1479	2005-06-15 21:13:38	172	592	2005-06-17 01:26:38	2	2006-02-15 21:30:53
1480	2005-06-15 21:17:17	2598	27	2005-06-23 22:01:17	1	2006-02-15 21:30:53
1481	2005-06-15 21:17:58	3041	125	2005-06-18 17:53:58	2	2006-02-15 21:30:53
\.


--
-- Data for Name: staff; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.staff (staff_id, first_name, last_name, address_id, email, store_id, active, username, password, last_update, picture) FROM stdin;
1	Mike	Hillyer	3	Mike.Hillyer@sakilastaff.com	1	t	Mike	8cb2237d0679ca88db6464eac60da96345513964	2006-02-15 04:57:16	\N
2	Jon	Stephens	4	Jon.Stephens@sakilastaff.com	2	t	Jon	8cb2237d0679ca88db6464eac60da96345513964	2006-02-15 04:57:16	\N
\.


--
-- Data for Name: store; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.store (store_id, manager_staff_id, address_id, last_update) FROM stdin;
1	1	1	2006-02-15 04:57:12
2	2	2	2006-02-15 04:57:12
\.


--
-- Name: actor_actor_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.actor_actor_id_seq', 200, true);


--
-- Name: address_address_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.address_address_id_seq', 605, true);


--
-- Name: category_category_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.category_category_id_seq', 16, true);


--
-- Name: city_city_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.city_city_id_seq', 600, true);


--
-- Name: country_country_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.country_country_id_seq', 109, true);


--
-- Name: customer_customer_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.customer_customer_id_seq', 599, true);


--
-- Name: film_film_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.film_film_id_seq', 1000, true);


--
-- Name: inventory_inventory_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.inventory_inventory_id_seq', 4581, true);


--
-- Name: language_language_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.language_language_id_seq', 6, true);


--
-- Name: payment_payment_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.payment_payment_id_seq', 32098, true);


--
-- Name: rental_rental_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.rental_rental_id_seq', 16049, true);


--
-- Name: staff_staff_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.staff_staff_id_seq', 2, true);


--
-- Name: store_store_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.store_store_id_seq', 2, true);


--
-- Name: actor actor_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.actor
    ADD CONSTRAINT actor_pkey PRIMARY KEY (actor_id);


--
-- Name: address address_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.address
    ADD CONSTRAINT address_pkey PRIMARY KEY (address_id);


--
-- Name: category category_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.category
    ADD CONSTRAINT category_pkey PRIMARY KEY (category_id);


--
-- Name: city city_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.city
    ADD CONSTRAINT city_pkey PRIMARY KEY (city_id);


--
-- Name: country country_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.country
    ADD CONSTRAINT country_pkey PRIMARY KEY (country_id);


--
-- Name: customer customer_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_pkey PRIMARY KEY (customer_id);


--
-- Name: film_actor film_actor_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.film_actor
    ADD CONSTRAINT film_actor_pkey PRIMARY KEY (actor_id, film_id);


--
-- Name: film_category film_category_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.film_category
    ADD CONSTRAINT film_category_pkey PRIMARY KEY (film_id, category_id);


--
-- Name: film film_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.film
    ADD CONSTRAINT film_pkey PRIMARY KEY (film_id);


--
-- Name: inventory inventory_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inventory
    ADD CONSTRAINT inventory_pkey PRIMARY KEY (inventory_id);


--
-- Name: language language_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.language
    ADD CONSTRAINT language_pkey PRIMARY KEY (language_id);


--
-- Name: payment payment_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment
    ADD CONSTRAINT payment_pkey PRIMARY KEY (payment_id);


--
-- Name: rental rental_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rental
    ADD CONSTRAINT rental_pkey PRIMARY KEY (rental_id);


--
-- Name: staff staff_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT staff_pkey PRIMARY KEY (staff_id);


--
-- Name: store store_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.store
    ADD CONSTRAINT store_pkey PRIMARY KEY (store_id);


--
-- Name: film_fulltext_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX film_fulltext_idx ON public.film USING gist (fulltext);


--
-- Name: idx_actor_last_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_actor_last_name ON public.actor USING btree (last_name);


--
-- Name: idx_fk_address_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_address_id ON public.customer USING btree (address_id);


--
-- Name: idx_fk_city_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_city_id ON public.address USING btree (city_id);


--
-- Name: idx_fk_country_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_country_id ON public.city USING btree (country_id);


--
-- Name: idx_fk_customer_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_customer_id ON public.payment USING btree (customer_id);


--
-- Name: idx_fk_film_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_film_id ON public.film_actor USING btree (film_id);


--
-- Name: idx_fk_inventory_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_inventory_id ON public.rental USING btree (inventory_id);


--
-- Name: idx_fk_language_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_language_id ON public.film USING btree (language_id);


--
-- Name: idx_fk_original_language_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_original_language_id ON public.film USING btree (original_language_id);


--
-- Name: idx_fk_payment_p2007_01_customer_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_payment_p2007_01_customer_id ON public.payment_p2007_01 USING btree (customer_id);


--
-- Name: idx_fk_payment_p2007_01_staff_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_payment_p2007_01_staff_id ON public.payment_p2007_01 USING btree (staff_id);


--
-- Name: idx_fk_payment_p2007_02_customer_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_payment_p2007_02_customer_id ON public.payment_p2007_02 USING btree (customer_id);


--
-- Name: idx_fk_payment_p2007_02_staff_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_payment_p2007_02_staff_id ON public.payment_p2007_02 USING btree (staff_id);


--
-- Name: idx_fk_payment_p2007_03_customer_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_payment_p2007_03_customer_id ON public.payment_p2007_03 USING btree (customer_id);


--
-- Name: idx_fk_payment_p2007_03_staff_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_payment_p2007_03_staff_id ON public.payment_p2007_03 USING btree (staff_id);


--
-- Name: idx_fk_payment_p2007_04_customer_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_payment_p2007_04_customer_id ON public.payment_p2007_04 USING btree (customer_id);


--
-- Name: idx_fk_payment_p2007_04_staff_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_payment_p2007_04_staff_id ON public.payment_p2007_04 USING btree (staff_id);


--
-- Name: idx_fk_payment_p2007_05_customer_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_payment_p2007_05_customer_id ON public.payment_p2007_05 USING btree (customer_id);


--
-- Name: idx_fk_payment_p2007_05_staff_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_payment_p2007_05_staff_id ON public.payment_p2007_05 USING btree (staff_id);


--
-- Name: idx_fk_payment_p2007_06_customer_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_payment_p2007_06_customer_id ON public.payment_p2007_06 USING btree (customer_id);


--
-- Name: idx_fk_payment_p2007_06_staff_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_payment_p2007_06_staff_id ON public.payment_p2007_06 USING btree (staff_id);


--
-- Name: idx_fk_staff_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_staff_id ON public.payment USING btree (staff_id);


--
-- Name: idx_fk_store_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_fk_store_id ON public.customer USING btree (store_id);


--
-- Name: idx_last_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_last_name ON public.customer USING btree (last_name);


--
-- Name: idx_store_id_film_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_store_id_film_id ON public.inventory USING btree (store_id, film_id);


--
-- Name: idx_title; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_title ON public.film USING btree (title);


--
-- Name: idx_unq_manager_staff_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_unq_manager_staff_id ON public.store USING btree (manager_staff_id);


--
-- Name: idx_unq_rental_rental_date_inventory_id_customer_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_unq_rental_rental_date_inventory_id_customer_id ON public.rental USING btree (rental_date, inventory_id, customer_id);


--
-- Name: payment payment_insert_p2007_01; Type: RULE; Schema: public; Owner: postgres
--

CREATE RULE payment_insert_p2007_01 AS
    ON INSERT TO public.payment
   WHERE ((new.payment_date >= '2007-01-01 00:00:00'::timestamp without time zone) AND (new.payment_date < '2007-02-01 00:00:00'::timestamp without time zone)) DO INSTEAD  INSERT INTO public.payment_p2007_01 (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
  VALUES (DEFAULT, new.customer_id, new.staff_id, new.rental_id, new.amount, new.payment_date);


--
-- Name: payment payment_insert_p2007_02; Type: RULE; Schema: public; Owner: postgres
--

CREATE RULE payment_insert_p2007_02 AS
    ON INSERT TO public.payment
   WHERE ((new.payment_date >= '2007-02-01 00:00:00'::timestamp without time zone) AND (new.payment_date < '2007-03-01 00:00:00'::timestamp without time zone)) DO INSTEAD  INSERT INTO public.payment_p2007_02 (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
  VALUES (DEFAULT, new.customer_id, new.staff_id, new.rental_id, new.amount, new.payment_date);


--
-- Name: payment payment_insert_p2007_03; Type: RULE; Schema: public; Owner: postgres
--

CREATE RULE payment_insert_p2007_03 AS
    ON INSERT TO public.payment
   WHERE ((new.payment_date >= '2007-03-01 00:00:00'::timestamp without time zone) AND (new.payment_date < '2007-04-01 00:00:00'::timestamp without time zone)) DO INSTEAD  INSERT INTO public.payment_p2007_03 (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
  VALUES (DEFAULT, new.customer_id, new.staff_id, new.rental_id, new.amount, new.payment_date);


--
-- Name: payment payment_insert_p2007_04; Type: RULE; Schema: public; Owner: postgres
--

CREATE RULE payment_insert_p2007_04 AS
    ON INSERT TO public.payment
   WHERE ((new.payment_date >= '2007-04-01 00:00:00'::timestamp without time zone) AND (new.payment_date < '2007-05-01 00:00:00'::timestamp without time zone)) DO INSTEAD  INSERT INTO public.payment_p2007_04 (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
  VALUES (DEFAULT, new.customer_id, new.staff_id, new.rental_id, new.amount, new.payment_date);


--
-- Name: payment payment_insert_p2007_05; Type: RULE; Schema: public; Owner: postgres
--

CREATE RULE payment_insert_p2007_05 AS
    ON INSERT TO public.payment
   WHERE ((new.payment_date >= '2007-05-01 00:00:00'::timestamp without time zone) AND (new.payment_date < '2007-06-01 00:00:00'::timestamp without time zone)) DO INSTEAD  INSERT INTO public.payment_p2007_05 (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
  VALUES (DEFAULT, new.customer_id, new.staff_id, new.rental_id, new.amount, new.payment_date);


--
-- Name: payment payment_insert_p2007_06; Type: RULE; Schema: public; Owner: postgres
--

CREATE RULE payment_insert_p2007_06 AS
    ON INSERT TO public.payment
   WHERE ((new.payment_date >= '2007-06-01 00:00:00'::timestamp without time zone) AND (new.payment_date < '2007-07-01 00:00:00'::timestamp without time zone)) DO INSTEAD  INSERT INTO public.payment_p2007_06 (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
  VALUES (DEFAULT, new.customer_id, new.staff_id, new.rental_id, new.amount, new.payment_date);


--
-- Name: film film_fulltext_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER film_fulltext_trigger BEFORE INSERT OR UPDATE ON public.film FOR EACH ROW EXECUTE FUNCTION tsvector_update_trigger('fulltext', 'pg_catalog.english', 'title', 'description');


--
-- Name: actor last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.actor FOR EACH ROW EXECUTE FUNCTION public.last_updated();


--
-- Name: address last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.address FOR EACH ROW EXECUTE FUNCTION public.last_updated();


--
-- Name: category last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.category FOR EACH ROW EXECUTE FUNCTION public.last_updated();


--
-- Name: city last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.city FOR EACH ROW EXECUTE FUNCTION public.last_updated();


--
-- Name: country last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.country FOR EACH ROW EXECUTE FUNCTION public.last_updated();


--
-- Name: customer last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.customer FOR EACH ROW EXECUTE FUNCTION public.last_updated();


--
-- Name: film last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.film FOR EACH ROW EXECUTE FUNCTION public.last_updated();


--
-- Name: film_actor last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.film_actor FOR EACH ROW EXECUTE FUNCTION public.last_updated();

ALTER TABLE public.film_actor DISABLE TRIGGER last_updated;


--
-- Name: film_category last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.film_category FOR EACH ROW EXECUTE FUNCTION public.last_updated();


--
-- Name: inventory last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.inventory FOR EACH ROW EXECUTE FUNCTION public.last_updated();


--
-- Name: language last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.language FOR EACH ROW EXECUTE FUNCTION public.last_updated();


--
-- Name: rental last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.rental FOR EACH ROW EXECUTE FUNCTION public.last_updated();

ALTER TABLE public.rental DISABLE TRIGGER last_updated;


--
-- Name: staff last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.staff FOR EACH ROW EXECUTE FUNCTION public.last_updated();


--
-- Name: store last_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER last_updated BEFORE UPDATE ON public.store FOR EACH ROW EXECUTE FUNCTION public.last_updated();


--
-- Name: address address_city_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.address
    ADD CONSTRAINT address_city_id_fkey FOREIGN KEY (city_id) REFERENCES public.city(city_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: city city_country_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.city
    ADD CONSTRAINT city_country_id_fkey FOREIGN KEY (country_id) REFERENCES public.country(country_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: customer customer_address_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_address_id_fkey FOREIGN KEY (address_id) REFERENCES public.address(address_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: customer customer_store_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_store_id_fkey FOREIGN KEY (store_id) REFERENCES public.store(store_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: film_actor film_actor_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.film_actor
    ADD CONSTRAINT film_actor_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.actor(actor_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: film_actor film_actor_film_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.film_actor
    ADD CONSTRAINT film_actor_film_id_fkey FOREIGN KEY (film_id) REFERENCES public.film(film_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: film_category film_category_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.film_category
    ADD CONSTRAINT film_category_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.category(category_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: film_category film_category_film_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.film_category
    ADD CONSTRAINT film_category_film_id_fkey FOREIGN KEY (film_id) REFERENCES public.film(film_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: film film_language_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.film
    ADD CONSTRAINT film_language_id_fkey FOREIGN KEY (language_id) REFERENCES public.language(language_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: film film_original_language_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.film
    ADD CONSTRAINT film_original_language_id_fkey FOREIGN KEY (original_language_id) REFERENCES public.language(language_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: inventory inventory_film_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inventory
    ADD CONSTRAINT inventory_film_id_fkey FOREIGN KEY (film_id) REFERENCES public.film(film_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: inventory inventory_store_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inventory
    ADD CONSTRAINT inventory_store_id_fkey FOREIGN KEY (store_id) REFERENCES public.store(store_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: payment payment_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment
    ADD CONSTRAINT payment_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: payment_p2007_01 payment_p2007_01_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_01
    ADD CONSTRAINT payment_p2007_01_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id);


--
-- Name: payment_p2007_01 payment_p2007_01_rental_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_01
    ADD CONSTRAINT payment_p2007_01_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES public.rental(rental_id);


--
-- Name: payment_p2007_01 payment_p2007_01_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_01
    ADD CONSTRAINT payment_p2007_01_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(staff_id);


--
-- Name: payment_p2007_02 payment_p2007_02_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_02
    ADD CONSTRAINT payment_p2007_02_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id);


--
-- Name: payment_p2007_02 payment_p2007_02_rental_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_02
    ADD CONSTRAINT payment_p2007_02_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES public.rental(rental_id);


--
-- Name: payment_p2007_02 payment_p2007_02_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_02
    ADD CONSTRAINT payment_p2007_02_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(staff_id);


--
-- Name: payment_p2007_03 payment_p2007_03_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_03
    ADD CONSTRAINT payment_p2007_03_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id);


--
-- Name: payment_p2007_03 payment_p2007_03_rental_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_03
    ADD CONSTRAINT payment_p2007_03_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES public.rental(rental_id);


--
-- Name: payment_p2007_03 payment_p2007_03_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_03
    ADD CONSTRAINT payment_p2007_03_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(staff_id);


--
-- Name: payment_p2007_04 payment_p2007_04_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_04
    ADD CONSTRAINT payment_p2007_04_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id);


--
-- Name: payment_p2007_04 payment_p2007_04_rental_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_04
    ADD CONSTRAINT payment_p2007_04_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES public.rental(rental_id);


--
-- Name: payment_p2007_04 payment_p2007_04_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_04
    ADD CONSTRAINT payment_p2007_04_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(staff_id);


--
-- Name: payment_p2007_05 payment_p2007_05_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_05
    ADD CONSTRAINT payment_p2007_05_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id);


--
-- Name: payment_p2007_05 payment_p2007_05_rental_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_05
    ADD CONSTRAINT payment_p2007_05_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES public.rental(rental_id);


--
-- Name: payment_p2007_05 payment_p2007_05_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_05
    ADD CONSTRAINT payment_p2007_05_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(staff_id);


--
-- Name: payment_p2007_06 payment_p2007_06_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_06
    ADD CONSTRAINT payment_p2007_06_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id);


--
-- Name: payment_p2007_06 payment_p2007_06_rental_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_06
    ADD CONSTRAINT payment_p2007_06_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES public.rental(rental_id);


--
-- Name: payment_p2007_06 payment_p2007_06_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_p2007_06
    ADD CONSTRAINT payment_p2007_06_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(staff_id);


--
-- Name: payment payment_rental_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment
    ADD CONSTRAINT payment_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES public.rental(rental_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: payment payment_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment
    ADD CONSTRAINT payment_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(staff_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: rental rental_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rental
    ADD CONSTRAINT rental_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: rental rental_inventory_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rental
    ADD CONSTRAINT rental_inventory_id_fkey FOREIGN KEY (inventory_id) REFERENCES public.inventory(inventory_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: rental rental_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rental
    ADD CONSTRAINT rental_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(staff_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: staff staff_address_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT staff_address_id_fkey FOREIGN KEY (address_id) REFERENCES public.address(address_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: staff staff_store_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT staff_store_id_fkey FOREIGN KEY (store_id) REFERENCES public.store(store_id);


--
-- Name: store store_address_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.store
    ADD CONSTRAINT store_address_id_fkey FOREIGN KEY (address_id) REFERENCES public.address(address_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: store store_manager_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.store
    ADD CONSTRAINT store_manager_staff_id_fkey FOREIGN KEY (manager_staff_id) REFERENCES public.staff(staff_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--

