import { Entity, Column, PrimaryGeneratedColumn } from 'typeorm';

@Entity('actor')
export class Actor {
  @PrimaryGeneratedColumn()
  actor_id: number;

  @Column()
  first_name: string;

  @Column('text')
  last_name: string;
}
