import { Entity, Column, PrimaryGeneratedColumn } from 'typeorm';

@Entity('film')
export class Film {
  @PrimaryGeneratedColumn()
  film_id: number;

  @Column()
  title: string;

  @Column('text')
  description: string;

  @Column('text')
  fulltext: string;

  @Column('int')
  length: number;

  @Column('int')
  release_year;
}
